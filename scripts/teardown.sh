#!/usr/bin/env bash
# Destroys an environment and removes its context from ~/.kube/config
# (bootstrap.sh's merge step, undone) so stale contexts for a cluster that
# no longer exists don't accumulate.
#
# Usage: scripts/teardown.sh [dev|prod]   (default: dev)
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

cluster_name="$(terraform -chdir="${env_dir}" output -raw cluster_name 2>/dev/null || echo "local-platform-${env_name}")"
context_name="kind-${cluster_name}"

terraform -chdir="${env_dir}" destroy

echo "==> Removing ${context_name} from ~/.kube/config"
kubectl config delete-context "${context_name}" >/dev/null 2>&1 || true
kubectl config delete-cluster "${context_name}" >/dev/null 2>&1 || true
kubectl config delete-user "${context_name}" >/dev/null 2>&1 || true

echo "==> Teardown complete (${env_name})."
