variable "cluster_name" {
  type    = string
  default = "local-platform-management"
}

# gha-runner-scale-set-controller/gha-runner-scale-set versions moved to
# gitops/management/platform/arc-{controller,runners}.yaml as of Milestone
# 5, Phase 1 -- ARC is Argo CD-managed now, not a Terraform helm_release.

variable "argocd_chart_version" {
  type        = string
  description = "argo/argo-cd Helm chart version"
  default     = "10.9.1"
}

# Same repo-creds template pattern as dev/prod's variables.tf -- see there
# for the full rationale. github_username/github_token are read from the
# same TF_VAR_github_username/TF_VAR_github_token already exported for
# dev/prod (Terraform env vars aren't per-module), so no new .env.local
# entries are needed for this cluster.
variable "github_org_url" {
  type    = string
  default = "https://github.com/chliddle/"
}

variable "github_username" {
  type        = string
  description = "GitHub username for the Argo CD repo-creds template. Set via TF_VAR_github_username."
}

variable "github_token" {
  type        = string
  sensitive   = true
  description = "Classic GitHub PAT (scopes: repo, read:packages) -- same credential dev/prod use. Set via TF_VAR_github_token env var only -- never commit, never put in a .tfvars file."
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
