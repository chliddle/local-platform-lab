variable "cluster_name" {
  type        = string
  description = "Name of the kind cluster"
}

variable "node_image" {
  type        = string
  description = "Pinned kindest/node image, repo@sha256 digest form"
  default     = "kindest/node:v1.29.2@sha256:51a1434a5397193442f0be2a297b488b6c919ce8a3931be0ce822606ea5ca245"
}

variable "kubeconfig_output_path" {
  type        = string
  description = "Path to write an isolated kubeconfig for this cluster (never merged into ~/.kube/config)"
}
