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
# everything else -- namespaces, RBAC, and even the platform's own
# tooling (ARC, monitoring, Gateway API, Istio) included. The only
# exception is credential material that genuinely can't be committed to
# Git for Argo CD to sync declaratively (GHCR pull secrets, the ARC
# runner PAT) -- those are script-bridged post-bootstrap (see
# scripts/sync-bootstrap-secrets.sh, called from scripts/bootstrap.sh),
# the same "script bridges ephemeral/credential values into a GitOps-
# managed cluster" pattern already used for the cross-cluster runner
# credential (scripts/sync-runner-creds.sh) and the monitoring stack's CA
# cert (scripts/sync-monitoring-targets.sh). This project used to also
# have Terraform create the `template-test-1`/`arc-systems`/`arc-runners`
# namespaces and their credential Secrets directly via typed
# kubernetes_* resources -- moved out entirely (Milestone 6) in favor of
# each consuming Argo CD Application's own `CreateNamespace=true` plus
# the script above placing credentials afterward.
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  values = [file("${path.module}/../../../platform/argocd/values-dev.yaml")]
}

# Everything Argo CD needs to start reconciling itself: the repo-creds
# Secret it reads this repo with, and the two root Applications (root,
# root-platform) that make it self-managing from here on. A local Helm
# chart (platform/argocd/bootstrap-chart), not a kubectl-apply
# terraform_data local-exec (the previous approach) -- confirmed live
# that approach was itself a workaround for two OTHER broken options:
# a "kubernetes_manifest" resource validates against the Application CRD
# schema at Terraform PLAN time, before helm_release.argocd above has
# installed that CRD, so it fails outright on a from-scratch apply;
# community kubectl-apply providers eagerly stat the kubeconfig file at
# provider-configure time, before it exists on a truly fresh apply, and
# fail the same way. helm_release hits neither problem -- no plan-time
# CRD schema check, and the kubeconfig is just a provider-config value
# resolved at apply time -- the same reason helm_release.argocd itself
# already works on a from-scratch cluster. depends_on is still needed:
# nothing about Terraform's resource graph otherwise knows this chart's
# Application manifests need that CRD to exist first.
resource "helm_release" "argocd_bootstrap" {
  name      = "argocd-bootstrap"
  namespace = "argocd"
  chart     = "${path.module}/../../../platform/argocd/bootstrap-chart"

  # helm provider v3: set/set_sensitive are list-of-object attributes, not
  # repeated nested blocks (same v3 shape change as the provider "kubernetes"
  # config block in providers.tf).
  set = [
    { name = "environment", value = "dev" },
    { name = "githubUsername", value = var.github_username },
    { name = "githubOrgUrl", value = var.github_org_url },
    { name = "githubRepoUrl", value = var.github_repo_url },
  ]
  set_sensitive = [
    { name = "githubToken", value = var.github_token },
  ]

  depends_on = [helm_release.argocd]
}
