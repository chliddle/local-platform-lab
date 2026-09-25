output "kubeconfig_path" {
  value = module.kind.kubeconfig_path
}

output "cluster_name" {
  value = module.kind.cluster_name
}

output "argocd_namespace" {
  value = helm_release.argocd.namespace
}
