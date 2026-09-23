#!/usr/bin/env bash
# Milestone 5, Phase 3: trusts both clusters' cert-manager-issued root CAs
# in the Mac's System keychain, so curl/Safari/Chrome validate
# *.{dev,prod}.platform.local with no -k/insecure flag. Host-level, not
# Terraform/GitOps-managed -- same category as everything else in this
# phase's host setup.
#
# Needs re-running after recreating dev or prod: cert-manager generates a
# fresh self-signed root key pair every time (it's not persisted outside
# the cluster, by design -- private keys never touch Git, see
# platform/cert-manager/config-{dev,prod}/root-ca.yaml), so the old
# trusted cert in the keychain no longer matches. The stale entry is
# harmless to leave behind (it's a trust decision on a public cert, not a
# credential) but can be removed manually if it bothers you:
#   sudo security delete-certificate -c local-platform-dev-root-ca /Library/Keychains/System.keychain
#
# Each `security add-trusted-cert` needs one interactive admin approval
# (Touch ID/password) -- not scriptable non-interactively, so this must be
# run directly in your own terminal, not piped through anything.
#
# Usage: scripts/trust-local-ca.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dev_kubeconfig="${repo_root}/terraform/environments/dev/kubeconfig-local-platform-dev"
prod_kubeconfig="${repo_root}/terraform/environments/prod/kubeconfig-local-platform-prod"

for kc in "$dev_kubeconfig" "$prod_kubeconfig"; do
  if [ ! -f "$kc" ]; then
    echo "error: kubeconfig not found at ${kc}. Run 'make bootstrap'/'make bootstrap-prod' first." >&2
    exit 1
  fi
done

ca_dir="$(mktemp -d)"
trap 'rm -rf "$ca_dir"' EXIT

KUBECONFIG="$dev_kubeconfig" kubectl -n cert-manager get secret dev-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d >"${ca_dir}/dev-root-ca.crt"
KUBECONFIG="$prod_kubeconfig" kubectl -n cert-manager get secret prod-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d >"${ca_dir}/prod-root-ca.crt"

echo "==> Trusting dev's root CA (you'll be prompted for admin approval)"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "${ca_dir}/dev-root-ca.crt"

echo "==> Trusting prod's root CA (you'll be prompted for admin approval)"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "${ca_dir}/prod-root-ca.crt"

echo "==> Done. Verify with:"
echo "  curl https://template-test-1.dev.platform.local/"
echo "  curl https://template-test-1.prod.platform.local/"
