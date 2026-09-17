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
# kubeconfig_path output. Its value is a plain input variable (known at plan
# time) but the output carries an explicit depends_on on the cluster
# resource, which Terraform propagates to every resource that consumes these
# provider configs -- so kubernetes/helm resources are correctly sequenced
# after the kind cluster actually exists, all within one apply.
provider "kubernetes" {
  config_path = module.kind.kubeconfig_path
}

provider "helm" {
  # helm provider v3 uses an object-typed attribute here, not a nested block.
  kubernetes = {
    config_path = module.kind.kubeconfig_path
  }
}
