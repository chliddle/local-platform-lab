#!/usr/bin/env bash
# Milestone 4, Phase C: extracts the ci-argocd-reader ServiceAccount's token
# and CA cert from dev and prod, resolves each cluster's current
# control-plane container IP on the shared `kind` Docker network, and writes
# one Secret per environment into the management cluster's arc-runners
# namespace (where self-hosted runner job pods run) -- so a workflow running
# there can query Argo CD's real Application status in both environments
# for cross-repo integration testing.
#
# A script, not cross-root terraform_remote_state: dev, prod, and management
# are independent Terraform roots by explicit project convention, and this
# only needs read access to kubeconfigs the host already has.
#
# Container IPs are NOT stable across `kind delete`/`create` -- re-run this
# after recreating dev, prod, or management.
#
# Usage: scripts/sync-runner-creds.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mgmt_kubeconfig="${repo_root}/terraform/environments/management/kubeconfig-local-platform-management"

if [ ! -f "$mgmt_kubeconfig" ]; then
  echo "error: management cluster kubeconfig not found at ${mgmt_kubeconfig}." >&2
  echo "Run 'make bootstrap-management' first." >&2
  exit 1
fi

for env in dev prod; do
  env_kubeconfig="${repo_root}/terraform/environments/${env}/kubeconfig-local-platform-${env}"
  if [ ! -f "$env_kubeconfig" ]; then
    echo "error: ${env} kubeconfig not found at ${env_kubeconfig}." >&2
    if [ "$env" = "dev" ]; then
      echo "Run 'make bootstrap' first." >&2
    else
      echo "Run 'make bootstrap-prod' first." >&2
    fi
    exit 1
  fi

  container_name="local-platform-${env}-control-plane"
  container_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$container_name")"
  if [ -z "$container_ip" ]; then
    echo "error: could not resolve ${container_name}'s IP on the kind Docker network." >&2
    exit 1
  fi

  token="$(KUBECONFIG="$env_kubeconfig" kubectl -n argocd get secret ci-argocd-reader-token -o jsonpath='{.data.token}' | base64 -d)"
  ca_crt_file="$(mktemp)"
  KUBECONFIG="$env_kubeconfig" kubectl -n argocd get secret ci-argocd-reader-token -o jsonpath='{.data.ca\.crt}' | base64 -d >"$ca_crt_file"

  echo "==> Writing ${env} credentials into the management cluster (server: https://${container_ip}:6443)"

  KUBECONFIG="$mgmt_kubeconfig" kubectl -n arc-runners create secret generic "${env}-argocd-reader" \
    --from-literal="server=https://${container_ip}:6443" \
    --from-literal="token=${token}" \
    --from-file="ca.crt=${ca_crt_file}" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$mgmt_kubeconfig" kubectl apply -f -

  rm -f "$ca_crt_file"
done

echo ""
echo "==> Done. Verify with:"
echo "  kubectl --kubeconfig ${mgmt_kubeconfig} -n arc-runners get secrets dev-argocd-reader prod-argocd-reader"
