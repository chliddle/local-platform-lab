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
  description = "GitHub username used to authenticate Argo CD (private repo) and the Kind node (private GHCR image). Set via TF_VAR_github_username."
}

variable "github_token" {
  type        = string
  sensitive   = true
  description = "GitHub PAT with repo read + read:packages scopes. Set via TF_VAR_github_token env var only -- never commit, never put in a .tfvars file."
}
