output "cluster_name" {
  value      = var.cluster_name
  depends_on = [terraform_data.kind_cluster]
}

# Changes every time the cluster is actually (re)created, unlike
# cluster_name/kubeconfig_path which stay constant across recreations.
# Downstream resources that can't otherwise detect "the cluster underneath
# me was replaced" (anything backed by local-exec rather than a real,
# refreshable Kubernetes API object) should include this in their own
# triggers_replace.
output "instance_id" {
  value = terraform_data.kind_cluster.id
}

output "kubeconfig_path" {
  value      = var.kubeconfig_output_path
  depends_on = [terraform_data.kind_cluster]
}
