#!/usr/bin/env bash
# Recreates the entire dev environment: Kind cluster, Argo CD, and the
# app-of-apps root Application. Idempotent -- safe to re-run.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_dir="${repo_root}/terraform/environments/dev"

# shellcheck disable=SC1091
if [ -f "${repo_root}/.env.local" ]; then
  set -a
  source "${repo_root}/.env.local"
  set +a
fi

echo "==> Checking prerequisites"

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker daemon is not running. Start Docker Desktop and re-run." >&2
  exit 1
fi

for cmd in kind kubectl helm terraform; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command '$cmd' not found on PATH." >&2
    exit 1
  fi
done

if [ -z "${TF_VAR_github_username:-}" ] || [ -z "${TF_VAR_github_token:-}" ] || [ -z "${TF_VAR_ghcr_token:-}" ]; then
  cat >&2 <<'EOF'
error: TF_VAR_github_username, TF_VAR_github_token, and TF_VAR_ghcr_token must be set.

These seed two Kubernetes secrets (never committed to Git):
  - an Argo CD repo-credentials secret, so it can read this private repo
  - a GHCR imagePullSecret, so the Kind node can pull the private
    hello-world image

Two separate tokens are needed -- fine-grained PATs have no "Packages"
permission at all, so GHCR auth only works with a classic PAT:

  TF_VAR_github_token: fine-grained PAT, scoped to this repo only,
    "Contents: Read-only"
  TF_VAR_ghcr_token: classic PAT, scope "read:packages" only

Then either:

  cp .env.local.example .env.local   # fill in the values, bootstrap.sh sources it

or:

  export TF_VAR_github_username=<your-github-username>
  export TF_VAR_github_token=<the-fine-grained-pat>
  export TF_VAR_ghcr_token=<the-classic-pat>
EOF
  exit 1
fi

echo "==> Applying Terraform (Kind cluster + Argo CD + GitOps root app)"
terraform -chdir="${env_dir}" init -upgrade
terraform -chdir="${env_dir}" apply -auto-approve

kubeconfig_path="$(terraform -chdir="${env_dir}" output -raw kubeconfig_path)"
argocd_namespace="$(terraform -chdir="${env_dir}" output -raw argocd_namespace)"

echo "==> Waiting for Argo CD server to be ready"
KUBECONFIG="${kubeconfig_path}" kubectl -n "${argocd_namespace}" rollout status deployment/argocd-server --timeout=180s

cat <<EOF

==> Bootstrap complete.

Use this cluster:
  export KUBECONFIG=${kubeconfig_path}

Argo CD UI (admin password below, then browse https://localhost:8080):
  kubectl -n ${argocd_namespace} port-forward svc/argocd-server 8080:443 &
  kubectl -n ${argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

Check the hello-world app synced:
  kubectl -n ${argocd_namespace} get application hello-world -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
EOF
