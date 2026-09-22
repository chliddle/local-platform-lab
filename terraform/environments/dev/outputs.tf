output "kubeconfig_path" {
  value = module.kind.kubeconfig_path
}

output "cluster_name" {
  value = module.kind.cluster_name
}

output "argocd_namespace" {
  value = kubernetes_namespace_v1.argocd.metadata[0].name
}
