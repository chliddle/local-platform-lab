terraform {
  required_version = ">= 1.5"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

# Both Kubernetes-facing providers are configured from module.kind's
# kubeconfig_path output, same pattern as dev/prod.
provider "kubernetes" {
  config_path = module.kind.kubeconfig_path
}

provider "helm" {
  # helm provider v3 uses an object-typed attribute here, not a nested block.
  kubernetes = {
    config_path = module.kind.kubeconfig_path
  }
}
