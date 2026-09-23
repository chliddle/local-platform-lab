module "kind" {
  source = "../../modules/kind-cluster"

  cluster_name           = var.cluster_name
  kubeconfig_output_path = "${abspath(path.module)}/kubeconfig-${var.cluster_name}"
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

# Milestone 5, Phase 1: this cluster's own platform tooling (ARC, BuildKit,
# and later the observability stack) is GitOps-managed like everything in
# dev/prod, not raw-Terraform-managed -- Argo CD itself is the one
# exception, installed directly for the same chicken-and-egg reason dev/prod
# install it directly (it can't deploy itself before it exists).
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [file("${path.module}/../../../platform/argocd/values-management.yaml")]
}

# Same repo-creds credential TEMPLATE dev/prod use (matched by URL prefix,
# so it already covers this platform repo's gitops/management/platform
# path with zero further changes). github_username/github_token reuse the
# same TF_VAR_github_username/TF_VAR_github_token already exported for
# dev/prod -- Terraform env vars aren't per-module, so no new .env.local
# entries are needed.
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

# Applied via kubectl apply local-exec, not a Terraform Kubernetes-manifest
# provider -- same reasoning as terraform_data.argocd_root_app in dev/prod
# (the Application CRD doesn't exist until helm_release.argocd finishes).
resource "terraform_data" "argocd_root_platform" {
  triggers_replace = [
    filesha256("${path.module}/../../../platform/argocd/root-platform-management.yaml"),
    module.kind.instance_id,
  ]

  provisioner "local-exec" {
    command = "kubectl --kubeconfig '${module.kind.kubeconfig_path}' apply -f '${path.module}/../../../platform/argocd/root-platform-management.yaml'"
  }

  depends_on = [helm_release.argocd, kubernetes_secret_v1.argocd_repo_creds]
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

# Milestone 5, Phase 2: the classic PAT already used for dev/prod's Argo CD
# repo-creds/GHCR pull secrets (var.github_token, `repo` scope -- already
# the widest-blast-radius credential in this platform, flagged in
# Milestone 4's Security implications and left as-is per the user's
# explicit call), reused here rather than minted fresh, so
# promote-platform.yml can push the prod branch forward. A materially
# different, narrower-scoped credential (e.g. Contents-only) was
# considered and explicitly not chosen: adding another credential when a
# suitable one already exists doesn't reduce this platform's actual attack
# surface, just its credential count.
resource "kubernetes_secret_v1" "platform_repo_push_credential" {
  metadata {
    name      = "platform-repo-push-credential"
    namespace = kubernetes_namespace_v1.arc_runners.metadata[0].name
  }

  data = {
    token = var.github_token
  }
}

# Milestone 4, Phase D (dev-argocd-reader/prod-argocd-reader) + Milestone 5,
# Phase 2 (platform-repo-push-credential): lets runner pods read exactly
# these named credential Secrets -- named by resource, not a blanket
# "secrets" grant, so a compromised job still can't read anything else in
# this namespace (e.g. the ARC runner's own PAT). "platform-runners-gha-rs-
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
    resource_names = ["dev-argocd-reader", "prod-argocd-reader", "platform-repo-push-credential"]
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
# GitOps-managed as of Milestone 5, Phase 1 -- see
# gitops/management/platform/buildkit.yaml and platform/buildkit/.
resource "kubernetes_namespace_v1" "buildkit" {
  metadata {
    name = "buildkit"
  }
}
