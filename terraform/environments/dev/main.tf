module "kind" {
  source = "../../modules/kind-cluster"

  cluster_name = var.cluster_name
  # abspath() so the kubeconfig_path output is safe to use from any working
  # directory (e.g. scripts/bootstrap.sh, invoked from the repo root) --
  # a bare "${path.module}/..." is only valid relative to this module's own
  # directory.
  kubeconfig_output_path = "${abspath(path.module)}/kubeconfig-${var.cluster_name}"
}

# KNOWN LIMITATION: if module.kind.terraform_data.kind_cluster is ever
# replaced (e.g. its kubeconfig_output_path trigger changes, as happened
# when this repo's directory moved), the kubernetes_namespace_v1/
# helm_release/kubernetes_secret_v1 resources below have no attribute that
# changes as a result, so nothing tells Terraform they need recreating too
# -- the first apply after such a change fails partway through ("namespace
# not found") with the cluster recreated but its contents orphaned in
# state. A `lifecycle.replace_triggered_by` fix was tried and reverted: it
# creates a genuine dependency cycle (destroying these resources needs the
# kubernetes/helm provider, which is configured from the same cluster
# resource being destroyed as part of the same replacement) --
# `terraform apply` errors with "Cycle: ..." rather than actually fixing
# anything. Recovery is simply re-running `terraform apply` (or
# `make bootstrap`) a second time: Terraform's refresh step correctly
# detects the orphaned resources as drift and recreates them.
resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [file("${path.module}/../../../platform/argocd/values-dev.yaml")]
}

# A credential TEMPLATE (secret-type: repo-creds), not a single-repo
# secret -- matched by URL PREFIX, so it covers this platform repo AND any
# self-service app-team repo onboarded later (e.g. template-test-1)
# with zero further Terraform changes. This is what makes app onboarding
# genuinely self-service: adding a new app is "commit an Application
# manifest to gitops/*/apps/", never "touch Terraform". All repos are
# private, so this credential is required -- comes from TF_VAR_github_token
# only, never committed.
resource "kubernetes_secret_v1" "argocd_repo_creds" {
  metadata {
    name      = "github-repo-creds"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }

  data = {
    type     = "git"
    url      = var.github_org_url
    username = var.github_username
    password = var.github_token
  }

  depends_on = [helm_release.argocd]
}

resource "kubernetes_namespace_v1" "hello_world" {
  metadata {
    name = "template-test-1"
  }
}

# Lets the Kind node pull the private ghcr.io/chliddle/template-test-1
# image. Referenced by name from deploy/base/deployment.yaml in that app's
# own repo (chliddle/template-test-1) -- our example/test app generated
# from the local-platform-lab-app-template template repo.
resource "kubernetes_secret_v1" "ghcr_pull" {
  metadata {
    name      = "ghcr-pull-secret"
    namespace = kubernetes_namespace_v1.hello_world.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          username = var.github_username
          password = var.github_token
          auth     = base64encode("${var.github_username}:${var.github_token}")
        }
      }
    })
  }
}

# Two app-of-apps root Applications, applied in one local-exec: "root"
# (gitops/dev/apps -- onboarded self-service apps, unchanged since
# Milestone 1) and "root-platform" (gitops/dev/platform -- MetalLB, Gateway
# API CRDs, Istio, and later cert-manager/monitoring, new in Milestone 5).
# Kept as separate root Applications/directories rather than merged into
# one, so the self-service-app-onboarding boundary documented in
# CLAUDE.md's Repository Structure stays exactly "add one Application
# manifest here" with nothing platform-shaped mixed in.
#
# These are the only application workload objects Terraform ever touches
# directly -- everything under gitops/dev/{apps,platform}/ is reconciled by
# Argo CD from Git, never applied by Terraform or CI directly.
#
# Applied via the kubectl CLI (like the kind cluster itself) rather than a
# Terraform Kubernetes-manifest provider: a CRD like Application doesn't
# exist until helm_release.argocd finishes, and both the "kubernetes_manifest"
# resource (validates against the CRD schema at plan time -- doesn't exist
# yet) and community kubectl-apply providers (which eagerly stat the
# kubeconfig file at provider-configure time, before it exists on a truly
# fresh apply) break the single-`terraform apply` bootstrap on a brand new
# cluster. `kubectl apply` sidesteps both: no plan-time schema check, and
# the kubeconfig path is just a string argument evaluated at apply time.
#
# This resource's own triggers_replace (below) works fine for cascading a
# cluster replacement -- unlike the typed Kubernetes resources above, a
# terraform_data local-exec destroy is just a shell command, not a
# provider-graph dependency, so it doesn't hit the cycle described above.
resource "terraform_data" "argocd_root_app" {
  triggers_replace = [
    filesha256("${path.module}/../../../platform/argocd/root-app.yaml"),
    filesha256("${path.module}/../../../platform/argocd/root-platform-dev.yaml"),
    # Re-apply if the cluster itself was recreated -- this resource has no
    # real remote object Terraform can refresh/detect drift on otherwise.
    module.kind.instance_id,
  ]

  provisioner "local-exec" {
    command = "kubectl --kubeconfig '${module.kind.kubeconfig_path}' apply -f '${path.module}/../../../platform/argocd/root-app.yaml' -f '${path.module}/../../../platform/argocd/root-platform-dev.yaml'"
  }

  depends_on = [helm_release.argocd, kubernetes_secret_v1.argocd_repo_creds]
}

# Milestone 5 redesign: dev hosts the platform's self-hosted CI runner
# directly (no separate management cluster -- see CLAUDE.md's GitHub
# Actions Runners section for why that was dropped: a 3rd concurrently-
# reconciling Kind cluster repeatedly starved the shared Docker Desktop VM
# badly enough to crash-loop the real control planes, confirmed live across
# several from-scratch bootstraps). The runner's own ServiceAccount reads
# Applications in THIS cluster's argocd namespace directly -- no remote
# credential extraction needed to check dev's own health, unlike prod
# (still a separate cluster, still read remotely -- see
# scripts/sync-runner-creds.sh and the arc_runners namespace below).
resource "kubernetes_role_v1" "argocd_application_reader" {
  metadata {
    name      = "argocd-application-reader"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "runner_reads_dev_argocd" {
  metadata {
    name      = "runner-reads-dev-argocd"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.argocd_application_reader.metadata[0].name
  }

  # ARC's own default ServiceAccount for this scale set's runner pods
  # (confirmed via the EphemeralRunnerSet's pod spec) -- carries no RBAC
  # until this binding.
  subject {
    kind      = "ServiceAccount"
    name      = "platform-runners-gha-rs-no-permission"
    namespace = kubernetes_namespace_v1.arc_runners.metadata[0].name
  }
}

resource "kubernetes_namespace_v1" "arc_systems" {
  metadata {
    name = "arc-systems"
  }
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

# The classic PAT already used for this cluster's own Argo CD repo-creds/
# GHCR pull secrets (var.github_token, `repo` scope -- already the widest-
# blast-radius credential in this platform, flagged in Milestone 4's
# Security implications and left as-is per the user's explicit call),
# reused here rather than minted fresh, so promote-platform.yml can push
# the prod branch forward.
resource "kubernetes_secret_v1" "platform_repo_push_credential" {
  metadata {
    name      = "platform-repo-push-credential"
    namespace = kubernetes_namespace_v1.arc_runners.metadata[0].name
  }

  data = {
    token = var.github_token
  }
}

# Lets runner pods read exactly these named credential Secrets -- named by
# resource, not a blanket "secrets" grant, so a compromised job still can't
# read anything else in this namespace (e.g. the ARC runner's own PAT).
# prod-argocd-reader is written here by scripts/sync-runner-creds.sh (prod
# is still a separate cluster, so checking it remotely still needs an
# extracted, portable credential -- unlike dev, see
# runner_reads_dev_argocd above).
resource "kubernetes_role_v1" "runner_reads_argocd_creds" {
  metadata {
    name      = "runner-reads-argocd-creds"
    namespace = kubernetes_namespace_v1.arc_runners.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["prod-argocd-reader", "platform-repo-push-credential"]
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

# Rootless, daemonless image builder -- runner pods build images by talking
# to it over the network instead (buildx's `remote` driver, wired up in the
# workflow itself). Namespace stays Terraform-managed (no credential lives
# here, but this keeps it symmetric with arc-systems/arc-runners rather than
# a special case); the Deployment/Service/NetworkPolicy themselves are
# GitOps-managed -- see gitops/dev/platform/buildkit.yaml and
# platform/buildkit/.
resource "kubernetes_namespace_v1" "buildkit" {
  metadata {
    name = "buildkit"
  }
}
