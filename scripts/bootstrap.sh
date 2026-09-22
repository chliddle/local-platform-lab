#!/usr/bin/env bash
# Recreates a whole environment: Kind cluster, Argo CD, and the app-of-apps
# root Application. Idempotent -- safe to re-run.
#
# Usage: scripts/bootstrap.sh [dev|prod]   (default: dev)
set -euo pipefail

env_name="${1:-dev}"
case "$env_name" in
  dev | prod) ;;
  *)
    echo "error: unknown environment '${env_name}' (expected dev or prod)" >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_dir="${repo_root}/terraform/environments/${env_name}"

# shellcheck disable=SC1091
if [ -f "${repo_root}/.env.local" ]; then
  set -a
  source "${repo_root}/.env.local"
  set +a
fi

echo "==> Checking prerequisites (${env_name})"

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

if [ -z "${TF_VAR_github_username:-}" ] || [ -z "${TF_VAR_github_token:-}" ]; then
  cat >&2 <<'EOF'
error: TF_VAR_github_username and TF_VAR_github_token must be set.

These seed two Kubernetes secrets (never committed to Git):
  - an Argo CD repo-credentials secret, so it can read this private repo
  - a GHCR imagePullSecret, so the Kind node can pull the private
    hello-world image

Create a classic GitHub PAT (not fine-grained -- fine-grained PATs have no
"Packages" permission at all, so GHCR auth requires classic) with scopes
repo + read:packages, then either:

  cp .env.local.example .env.local   # fill in the values, bootstrap.sh sources it

or:

  export TF_VAR_github_username=<your-github-username>
  export TF_VAR_github_token=<the-pat>
EOF
  exit 1
fi

echo "==> Applying Terraform (Kind cluster + Argo CD + GitOps root app)"
terraform -chdir="${env_dir}" init -upgrade
terraform -chdir="${env_dir}" apply -auto-approve

kubeconfig_path="$(terraform -chdir="${env_dir}" output -raw kubeconfig_path)"
argocd_namespace="$(terraform -chdir="${env_dir}" output -raw argocd_namespace)"
cluster_name="$(terraform -chdir="${env_dir}" output -raw cluster_name)"

echo "==> Waiting for Argo CD server to be ready"
KUBECONFIG="${kubeconfig_path}" kubectl -n "${argocd_namespace}" rollout status deployment/argocd-server --timeout=180s

echo "==> Merging context into ~/.kube/config"
mkdir -p "${HOME}/.kube"
[ -f "${HOME}/.kube/config" ] && cp "${HOME}/.kube/config" "${HOME}/.kube/config.bak"
KUBECONFIG="${HOME}/.kube/config:${kubeconfig_path}" kubectl config view --flatten >"${HOME}/.kube/config.new"
mv "${HOME}/.kube/config.new" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
context_name="kind-${cluster_name}"

cat <<EOF

==> Bootstrap complete (${env_name}).

Use this cluster (merged into ~/.kube/config -- the isolated
${kubeconfig_path} still works too, e.g. for scripting):
  kubectl config use-context ${context_name}

Argo CD UI (admin password below, then browse https://localhost:8080):
  kubectl -n ${argocd_namespace} port-forward svc/argocd-server 8080:443 &
  kubectl -n ${argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

Check the hello-world app synced:
  kubectl -n ${argocd_namespace} get application hello-world -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
EOF
