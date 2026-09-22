variable "cluster_name" {
  type    = string
  default = "local-platform-prod"
}

variable "argocd_chart_version" {
  type        = string
  description = "argo/argo-cd Helm chart version"
  default     = "10.9.1"
}

variable "github_repo_url" {
  type        = string
  description = "HTTPS URL of this repo, used as the Argo CD GitOps source"
  default     = "https://github.com/chliddle/local-platform-lab.git"
}

variable "github_org_url" {
  type        = string
  description = "URL prefix for the Argo CD repo-creds credential template -- covers every repo under this GitHub account (this platform repo and any self-service app repo onboarded later) with no per-repo Terraform change needed."
  default     = "https://github.com/chliddle/"
}

variable "github_username" {
  type        = string
  description = "GitHub username, used for both the Argo CD repo credential and the GHCR pull secret. Set via TF_VAR_github_username."
}

# Classic PAT (not fine-grained -- fine-grained PATs have no "Packages"
# permission at all, so GHCR auth requires classic). Scopes: repo,
# read:packages. Used for both the Argo CD repo credential and the GHCR
# imagePullSecret.
variable "github_token" {
  type        = string
  sensitive   = true
  description = "Classic GitHub PAT, scopes: repo + read:packages. Set via TF_VAR_github_token env var only -- never commit, never put in a .tfvars file."
}
