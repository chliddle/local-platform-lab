resource "local_file" "kind_config" {
  filename = "${path.module}/generated/kind-config-${var.cluster_name}.yaml"
  content = templatefile("${path.module}/templates/kind-config.yaml.tpl", {
    cluster_name = var.cluster_name
    node_image   = var.node_image
  })
}

# kind has no first-party Terraform provider we trust for full config coverage,
# so we drive the CLI directly. The create step is defensive (checks for an
# existing cluster) so a manually-deleted cluster with stale Terraform state
# doesn't hard-fail; triggers_replace forces recreation when the rendered kind
# config actually changes.
resource "terraform_data" "kind_cluster" {
  # Destroy-time provisioners may only reference the resource's own `self`
  # attributes (not other resources or variables directly), so the cluster
  # name is threaded through as `input` specifically to be available as
  # `self.input` at destroy time.
  input = var.cluster_name

  triggers_replace = [
    local_file.kind_config.content,
    var.kubeconfig_output_path,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      if kind get clusters | grep -qx "${var.cluster_name}"; then
        echo "kind cluster '${var.cluster_name}' already exists, skipping create"
      else
        kind create cluster \
          --name "${var.cluster_name}" \
          --config "${local_file.kind_config.filename}" \
          --kubeconfig "${var.kubeconfig_output_path}"
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kind delete cluster --name ${self.input} || true"
  }

  depends_on = [local_file.kind_config]
}
