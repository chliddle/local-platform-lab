terraform {
  required_version = ">= 1.5"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

# Milestone 6: Terraform's scope shrank to bootstrapping Argo CD only
# (see main.tf's helm_release.argocd comment) -- the kubernetes provider
# is gone along with the last kubernetes_* typed resource it was for.
# helm is configured from module.kind's kubeconfig_path output. Its value
# is a plain input variable (known at plan time) but the output carries
# an explicit depends_on on the cluster resource, which Terraform
# propagates to every resource that consumes this provider config -- so
# helm_release resources are correctly sequenced after the kind cluster
# actually exists, all within one apply.
provider "helm" {
  # helm provider v3 uses an object-typed attribute here, not a nested block.
  kubernetes = {
    config_path = module.kind.kubeconfig_path
  }
}
