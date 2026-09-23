output "kubeconfig_path" {
  value = module.kind.kubeconfig_path
}

output "cluster_name" {
  value = module.kind.cluster_name
}

output "argocd_namespace" {
  value = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "arc_systems_namespace" {
  value = kubernetes_namespace_v1.arc_systems.metadata[0].name
}

output "arc_runners_namespace" {
  value = kubernetes_namespace_v1.arc_runners.metadata[0].name
}
