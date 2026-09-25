module "kind" {
  source = "../../modules/kind-cluster"

  cluster_name = var.cluster_name
  # abspath() so the kubeconfig_path output is safe to use from any working
  # directory (e.g. scripts/bootstrap.sh, invoked from the repo root) --
  # a bare "${path.module}/..." is only valid relative to this module's own
  # directory.
  kubeconfig_output_path = "${abspath(path.module)}/kubeconfig-${var.cluster_name}"
}

# Terraform's job stops here: bootstrap Argo CD, then Argo CD manages
# everything else -- namespaces, RBAC, and workload-credential Secrets
# included. See terraform/environments/dev/main.tf's matching comment for
# the full reasoning; this file stays symmetric with dev except dev also
# hosts ARC (self-hosted CI runner), which prod has no equivalent of.
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  values = [file("${path.module}/../../../platform/argocd/values-prod.yaml")]
}

# Everything Argo CD needs to start reconciling itself -- see
# terraform/environments/dev/main.tf's helm_release.argocd_bootstrap
# comment for why this is a local Helm chart rather than a kubectl-apply
# terraform_data local-exec.
resource "helm_release" "argocd_bootstrap" {
  name      = "argocd-bootstrap"
  namespace = "argocd"
  chart     = "${path.module}/../../../platform/argocd/bootstrap-chart"

  set = [
    { name = "environment", value = "prod" },
    { name = "githubUsername", value = var.github_username },
    { name = "githubOrgUrl", value = var.github_org_url },
    { name = "githubRepoUrl", value = var.github_repo_url },
  ]
  set_sensitive = [
    { name = "githubToken", value = var.github_token },
  ]

  depends_on = [helm_release.argocd]
}
