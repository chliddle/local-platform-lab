module "kind" {
  source = "../../modules/kind-cluster"

  cluster_name           = var.cluster_name
  kubeconfig_output_path = "${abspath(path.module)}/kubeconfig-${var.cluster_name}"
}

resource "kubernetes_namespace_v1" "arc_systems" {
  metadata {
    name = "arc-systems"
  }
}

# The controller: manages the AutoscalingRunnerSet/AutoscalingListener/
# EphemeralRunnerSet/EphemeralRunner CRDs. No GitHub credential of its own --
# each scale set release below carries its own repo-scoped credential.
resource "helm_release" "arc_controller" {
  name       = "arc"
  namespace  = kubernetes_namespace_v1.arc_systems.metadata[0].name
  repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart      = "gha-runner-scale-set-controller"
  version    = var.arc_chart_version
}

resource "kubernetes_namespace_v1" "arc_runners" {
  metadata {
    name = "arc-runners"
  }
}

# Fine-grained PAT, scoped only to chliddle/local-platform-lab (Repository
# administration: Read and write -- the same permission a GitHub App would
# need for this). Lives only as a Kubernetes Secret in this cluster, never
# as a GitHub Actions repo secret. `github_token` is the exact key name
# ARC's gha-runner-scale-set chart expects for PAT-based auth.
resource "kubernetes_secret_v1" "platform_runner_github_credential" {
  metadata {
    name      = "platform-runner-github-credential"
    namespace = kubernetes_namespace_v1.arc_runners.metadata[0].name
  }

  data = {
    github_token = var.arc_runner_pat
  }
}

# containerMode is deliberately left unset: the default bare-runner-pod
# template has no dind sidecar, no Docker socket, and no extra RBAC bound to
# the runner pods themselves. Container image builds go out over the
# network to a rootless BuildKit Service instead (Phase B) -- mounting the
# host's Docker socket or a privileged DinD sidecar are both known
# host-escape vectors and are ruled out for this project (CLAUDE.md,
# Milestone 4).
resource "helm_release" "platform_runners" {
  name       = "platform-runners"
  namespace  = kubernetes_namespace_v1.arc_runners.metadata[0].name
  repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart      = "gha-runner-scale-set"
  version    = var.arc_chart_version

  values = [yamlencode({
    githubConfigUrl    = "https://github.com/chliddle/local-platform-lab"
    githubConfigSecret = kubernetes_secret_v1.platform_runner_github_credential.metadata[0].name
    runnerScaleSetName = "platform-runners"
    minRunners         = 0
    # Single Docker host, no concurrency headroom to give away.
    maxRunners = 1
  })]

  depends_on = [helm_release.arc_controller]
}

# Milestone 4, Phase D: lets runner pods read exactly the two credential
# Secrets scripts/sync-runner-creds.sh writes here (dev-argocd-reader,
# prod-argocd-reader) -- named by resource, not a blanket "secrets" grant,
# so a compromised job still can't read anything else in this namespace
# (e.g. the GitHub App/PAT credential itself). "platform-runners-gha-rs-
# no-permission" is ARC's own default ServiceAccount for this scale set's
# runner pods, confirmed via the EphemeralRunnerSet's pod spec -- its name
# is accurate, it carries no RBAC until this binding.
resource "kubernetes_role_v1" "runner_reads_argocd_creds" {
  metadata {
    name      = "runner-reads-argocd-creds"
    namespace = kubernetes_namespace_v1.arc_runners.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["dev-argocd-reader", "prod-argocd-reader"]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "runner_reads_argocd_creds" {
  metadata {
    name      = "runner-reads-argocd-creds"
    namespace = kubernetes_namespace_v1.arc_runners.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.runner_reads_argocd_creds.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "platform-runners-gha-rs-no-permission"
    namespace = kubernetes_namespace_v1.arc_runners.metadata[0].name
  }
}

# Rootless, daemonless image builder. Mounting the host's Docker socket or
# running a privileged Docker-in-Docker sidecar are both well-known
# host-escape vectors and are ruled out for this project (CLAUDE.md,
# Milestone 4) -- runner pods build images by talking to this Service over
# the network instead (buildx's `remote` driver, wired up in the workflow
# itself). Manifest follows moby/buildkit's own reference Kubernetes
# example (examples/kubernetes/deployment+service.rootless.yaml), pinned to
# a digest rather than a floating tag.
resource "kubernetes_namespace_v1" "buildkit" {
  metadata {
    name = "buildkit"
  }
}

resource "kubernetes_deployment_v1" "buildkitd" {
  metadata {
    name      = "buildkitd"
    namespace = kubernetes_namespace_v1.buildkit.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "buildkitd"
      }
    }

    template {
      metadata {
        labels = {
          app = "buildkitd"
        }
        annotations = {
          "container.apparmor.security.beta.kubernetes.io/buildkitd" = "unconfined"
        }
      }

      spec {
        container {
          name  = "buildkitd"
          image = "moby/buildkit:v0.33.0-rootless@sha256:80b15f0735e87bab7bf59ec4d695dfb4a7cfb25521cf56dc75d6f256285b63ef"

          args = [
            "--addr", "unix:///run/user/1000/buildkit/buildkitd.sock",
            "--addr", "tcp://0.0.0.0:1234",
            "--oci-worker-no-process-sandbox",
          ]

          port {
            container_port = 1234
          }

          security_context {
            run_as_user  = 1000
            run_as_group = 1000
            seccomp_profile {
              type = "Unconfined"
            }
          }

          readiness_probe {
            exec {
              command = ["buildctl", "debug", "workers"]
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }

          liveness_probe {
            exec {
              command = ["buildctl", "debug", "workers"]
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "buildkitd" {
  metadata {
    name      = "buildkitd"
    namespace = kubernetes_namespace_v1.buildkit.metadata[0].name
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "buildkitd"
    }

    port {
      port        = 1234
      target_port = 1234
    }
  }
}

# BuildKit executes arbitrary Dockerfile instructions with no auth of its
# own -- restricting ingress to pods in the arc-runners namespace (the only
# pods that should ever be building images) keeps a compromised pod
# elsewhere in this cluster from reaching it. Matched via the namespace's
# built-in kubernetes.io/metadata.name label (auto-set since Kubernetes
# 1.21), not a hand-applied label that could drift.
resource "kubernetes_network_policy_v1" "buildkitd" {
  metadata {
    name      = "buildkitd-allow-runners-only"
    namespace = kubernetes_namespace_v1.buildkit.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "buildkitd"
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace_v1.arc_runners.metadata[0].name
          }
        }
      }
      ports {
        port     = 1234
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }
}
