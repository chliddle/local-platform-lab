#!/usr/bin/env bash
# Milestone 6: places the credential Secrets Terraform used to create
# directly (kubernetes_secret_v1.ghcr_pull, platform_runner_github_credential,
# platform_repo_push_credential) now that Terraform's scope has shrunk to
# "bootstrap Argo CD only" -- everything else, namespaces included, is
# Argo CD-managed. Real credential material can't be committed to Git for
# Argo CD to sync declaratively, so this bridges it the same way
# scripts/sync-runner-creds.sh (a cross-cluster credential) and
# scripts/sync-monitoring-targets.sh (cert-manager's CA cert) already do:
# a script, run post-bootstrap, reading values only the host environment
# has.
#
# Reads the exact same TF_VAR_* env vars scripts/bootstrap.sh already
# requires and sources from .env.local -- no new credential-management
# mechanism, just a different place the same values get consumed.
#
# Namespaces are created idempotently here too (belt-and-suspenders): the
# consuming Argo CD Applications also carry CreateNamespace=true, but this
# script can't depend on winning that race, and a Secret write 404s if its
# namespace doesn't exist yet (confirmed live, same reasoning
# sync-monitoring-targets.sh already documents for the monitoring
# namespace).
#
# Idempotent (kubectl ... --dry-run=client -o yaml | kubectl apply -f -)
# -- safe to re-run. Called automatically by scripts/bootstrap.sh, before
# the Synced+Healthy wait: the Applications that need these Secrets can't
# go Healthy without them.
#
# Usage: scripts/sync-bootstrap-secrets.sh <dev|prod>
set -euo pipefail

env_name="${1:?usage: sync-bootstrap-secrets.sh <dev|prod>}"
case "$env_name" in
  dev | prod) ;;
  *)
    echo "error: unknown environment '${env_name}' (expected dev or prod)" >&2
    exit 1
    ;;
esac

: "${TF_VAR_github_username:?TF_VAR_github_username must be set (see .env.local)}"
: "${TF_VAR_github_token:?TF_VAR_github_token must be set (see .env.local)}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/terraform/environments/${env_name}/kubeconfig-local-platform-${env_name}"

if [ ! -f "$kubeconfig" ]; then
  echo "error: ${env_name} kubeconfig not found at ${kubeconfig}. Run 'make bootstrap'/'make bootstrap-prod' first." >&2
  exit 1
fi

create_namespace() {
  KUBECONFIG="$kubeconfig" kubectl create namespace "$1" --dry-run=client -o yaml \
    | KUBECONFIG="$kubeconfig" kubectl apply -f -
}

write_ghcr_pull_secret() {
  local namespace="$1"
  KUBECONFIG="$kubeconfig" kubectl -n "$namespace" create secret docker-registry ghcr-pull-secret \
    --docker-server=ghcr.io \
    --docker-username="$TF_VAR_github_username" \
    --docker-password="$TF_VAR_github_token" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$kubeconfig" kubectl apply -f -
}

if [ "$env_name" = "dev" ]; then
  : "${TF_VAR_arc_runner_pat:?TF_VAR_arc_runner_pat must be set (see .env.local)}"

  echo "==> [dev] arc-runners: namespace + credential Secrets"
  create_namespace arc-runners
  KUBECONFIG="$kubeconfig" kubectl -n arc-runners create secret generic platform-runner-github-credential \
    --from-literal="github_token=${TF_VAR_arc_runner_pat}" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$kubeconfig" kubectl apply -f -
  KUBECONFIG="$kubeconfig" kubectl -n arc-runners create secret generic platform-repo-push-credential \
    --from-literal="token=${TF_VAR_github_token}" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$kubeconfig" kubectl apply -f -

  echo "==> [dev] template-test-1 deployment-strategy variants: namespaces + GHCR pull secrets"
  for variant in rolling bluegreen canary; do
    ns="template-test-1-${variant}"
    create_namespace "$ns"
    write_ghcr_pull_secret "$ns"
  done
else
  echo "==> [prod] template-test-1: namespace + GHCR pull secret"
  create_namespace template-test-1
  write_ghcr_pull_secret template-test-1
fi

echo ""
echo "==> Done."
