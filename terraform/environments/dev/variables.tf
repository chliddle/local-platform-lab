variable "cluster_name" {
  type    = string
  default = "local-platform-dev"
}

variable "argocd_chart_version" {
  type        = string
  description = "argo/argo-cd Helm chart version"
  default     = "10.9.1"
}

variable "github_repo_url" {
  type        = string
  description = "HTTPS URL of this repo, used as the Argo CD GitOps source"
  default     = "https://github.com/chliddle/local-platform.git"
}

variable "github_username" {
  type        = string
  description = "GitHub username, used for both the Argo CD repo credential and the GHCR pull secret. Set via TF_VAR_github_username."
}

# Two separate tokens because fine-grained PATs have no "Packages"
# permission at all -- GHCR auth only works with a classic PAT.
variable "github_token" {
  type        = string
  sensitive   = true
  description = "Fine-grained PAT scoped to this repo only, Contents: Read-only. Used for the Argo CD repo credential. Set via TF_VAR_github_token env var only -- never commit, never put in a .tfvars file."
}

variable "ghcr_token" {
  type        = string
  sensitive   = true
  description = "Classic PAT with only the read:packages scope. Used for the Kind node's GHCR imagePullSecret. Set via TF_VAR_ghcr_token env var only -- never commit, never put in a .tfvars file."
}
