variable "cluster_name" {
  type    = string
  default = "local-platform-management"
}

# gha-runner-scale-set-controller and gha-runner-scale-set release in
# lockstep -- both charts always use this same version.
variable "arc_chart_version" {
  type        = string
  description = "actions-runner-controller-charts version, from oci://ghcr.io/actions/actions-runner-controller-charts"
  default     = "0.14.2"
}

# Fine-grained PAT, scoped only to chliddle/local-platform-lab, permission
# Repository administration: Read and write. A GitHub App would need the
# identical permission and offers a shorter-lived token in exchange for
# more setup ceremony -- for this single-owner project a PAT was chosen
# instead. Set via TF_VAR_arc_runner_pat, never committed.
variable "arc_runner_pat" {
  type        = string
  sensitive   = true
  description = "Fine-grained GitHub PAT, scoped only to chliddle/local-platform-lab, permission Repository administration: Read and write. Set via TF_VAR_arc_runner_pat env var only -- never commit, never put in a .tfvars file."
}
