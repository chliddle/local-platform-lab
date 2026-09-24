#!/usr/bin/env bash
# Milestone 4, Phase C, redesigned for Milestone 5 (dev hosts the platform's
# self-hosted CI runner directly -- see CLAUDE.md's GitHub Actions Runners
# section for why the separate management cluster was dropped): extracts
# prod's ci-argocd-reader ServiceAccount token and CA cert, resolves prod's
# current control-plane container IP on the shared `kind` Docker network,
# and writes one Secret into dev's arc-runners namespace (where the runner's
# job pods actually run) -- so a workflow running there can query prod's
# real Argo CD Application status for cross-repo integration testing and
# the prod promotion gate.
#
# dev doesn't need this for itself anymore: the runner's own ServiceAccount
# reads dev's own Applications directly, in-cluster (see
# terraform/environments/dev/main.tf's runner_reads_dev_argocd binding) --
# only a genuinely separate cluster (prod) still needs a portable,
# extracted credential.
#
# A script, not cross-root terraform_remote_state: dev and prod are
# independent Terraform roots by explicit project convention, and this only
# needs read access to kubeconfigs the host already has.
#
# prod's container IP is NOT stable across `kind delete`/`create` -- re-run
# this after recreating prod (or dev). Called automatically by
# scripts/up.sh.
#
# Usage: scripts/sync-runner-creds.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dev_kubeconfig="${repo_root}/terraform/environments/dev/kubeconfig-local-platform-dev"
prod_kubeconfig="${repo_root}/terraform/environments/prod/kubeconfig-local-platform-prod"

if [ ! -f "$dev_kubeconfig" ]; then
  echo "error: dev kubeconfig not found at ${dev_kubeconfig}. Run 'make bootstrap' first." >&2
  exit 1
fi
if [ ! -f "$prod_kubeconfig" ]; then
  echo "error: prod kubeconfig not found at ${prod_kubeconfig}. Run 'make bootstrap-prod' first." >&2
  exit 1
fi

container_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' local-platform-prod-control-plane)"
if [ -z "$container_ip" ]; then
  echo "error: could not resolve local-platform-prod-control-plane's IP on the kind Docker network." >&2
  exit 1
fi

token="$(KUBECONFIG="$prod_kubeconfig" kubectl -n argocd get secret ci-argocd-reader-token -o jsonpath='{.data.token}' | base64 -d)"
ca_crt_file="$(mktemp)"
trap 'rm -f "$ca_crt_file"' EXIT
KUBECONFIG="$prod_kubeconfig" kubectl -n argocd get secret ci-argocd-reader-token -o jsonpath='{.data.ca\.crt}' | base64 -d >"$ca_crt_file"

echo "==> Writing prod credentials into dev's arc-runners namespace (server: https://${container_ip}:6443)"

KUBECONFIG="$dev_kubeconfig" kubectl -n arc-runners create secret generic prod-argocd-reader \
  --from-literal="server=https://${container_ip}:6443" \
  --from-literal="token=${token}" \
  --from-file="ca.crt=${ca_crt_file}" \
  --dry-run=client -o yaml \
  | KUBECONFIG="$dev_kubeconfig" kubectl apply -f -

echo ""
echo "==> Done. Verify with:"
echo "  kubectl --kubeconfig ${dev_kubeconfig} -n arc-runners get secret prod-argocd-reader"
