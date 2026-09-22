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

# The single app-of-apps root Application. This is the only application
# workload object Terraform ever touches directly -- everything under
# gitops/dev/apps/ (and the template-test-1 Deployment/Service it points to) is
# reconciled by Argo CD from Git, never applied by Terraform or CI directly.
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
    # Re-apply if the cluster itself was recreated -- this resource has no
    # real remote object Terraform can refresh/detect drift on otherwise.
    module.kind.instance_id,
  ]

  provisioner "local-exec" {
    command = "kubectl --kubeconfig '${module.kind.kubeconfig_path}' apply -f '${path.module}/../../../platform/argocd/root-app.yaml'"
  }

  depends_on = [helm_release.argocd, kubernetes_secret_v1.argocd_repo_creds]
}
