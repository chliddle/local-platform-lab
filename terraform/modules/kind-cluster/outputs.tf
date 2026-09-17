output "cluster_name" {
  value      = var.cluster_name
  depends_on = [terraform_data.kind_cluster]
}

output "kubeconfig_path" {
  value      = var.kubeconfig_output_path
  depends_on = [terraform_data.kind_cluster]
}
