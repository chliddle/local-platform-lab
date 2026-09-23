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
