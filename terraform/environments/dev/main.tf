module "kind" {
  source = "../../modules/kind-cluster"

  cluster_name = var.cluster_name
  # abspath() so the kubeconfig_path output is safe to use from any working
  # directory (e.g. scripts/bootstrap.sh, invoked from the repo root) --
  # a bare "${path.module}/..." is only valid relative to this module's own
  # directory.
  kubeconfig_output_path = "${abspath(path.module)}/kubeconfig-${var.cluster_name}"
}

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
# self-service app-team repo onboarded later (e.g. local-platform-lab-app-1)
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
    name = "hello-world"
  }
}

# Lets the Kind node pull the private ghcr.io/chliddle/hello-world image.
# Referenced by name from apps/hello-world/k8s/base/deployment.yaml.
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
# gitops/dev/apps/ (and the hello-world Deployment/Service it points to) is
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
