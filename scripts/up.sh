#!/usr/bin/env bash
# Brings up the whole platform in one command: both clusters, the
# cross-cluster credential sync the runner needs to check prod (Milestone
# 4, redesigned in Milestone 5 -- dev hosts the runner directly now, so
# only prod's credential needs copying), and the host-level setup
# Milestone 5's local HTTPS access needs. Idempotent -- safe to re-run
# (each step it calls is).
#
# Clusters bootstrap one at a time, and bootstrap.sh now blocks until every
# Application in that cluster is Synced+Healthy before returning -- not
# just until Argo CD itself is up. Confirmed live (Milestone 5, Phase 4)
# this matters: bootstrapping clusters concurrently let their reconcile
# storms (first-time chart/image pulls, CRD registration, webhook cert
# generation) overlap and starve the shared Docker Desktop VM badly enough
# to make the real Kubernetes control plane lose leader election, not just
# Argo CD. Slower end to end, but each cluster is genuinely settled before
# the next one's storm begins, so they don't compound.
#
# The last three steps run real sudo commands interactively (docker-mac-
# net-connect as a root service, binding dnsmasq to port 53, trusting a
# CA in the System keychain) -- not scriptable non-interactively by
# design (see scripts/setup-mac-networking.sh, setup-local-dns.sh,
# trust-local-ca.sh for why each one specifically needs it). Expect a
# password/Touch ID prompt or two.
#
# Usage: scripts/up.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> [1/6] Bootstrapping dev cluster (waits for full health)"
"${repo_root}/scripts/bootstrap.sh" dev

echo "==> [2/6] Bootstrapping prod cluster (waits for full health)"
"${repo_root}/scripts/bootstrap.sh" prod

echo "==> [3/6] Syncing prod's Argo CD read credential into dev (for cross-cluster CI checks)"
"${repo_root}/scripts/sync-runner-creds.sh"

echo "==> [4/6] Checking Mac -> cluster network routing"
"${repo_root}/scripts/setup-mac-networking.sh"

echo "==> [5/6] Setting up local DNS (*.dev.platform.local, *.prod.platform.local)"
"${repo_root}/scripts/setup-local-dns.sh"

echo "==> [6/6] Trusting both clusters' local CAs"
"${repo_root}/scripts/trust-local-ca.sh"

# Milestone 6 dropped MetalLB -- reaching the Gateway now needs an
# explicit :<nodePort> suffix (see platform/gateway-api/examples/
# gateway.yaml's comment). Read live, not hardcoded.
dev_kubeconfig="${repo_root}/terraform/environments/dev/kubeconfig-local-platform-dev"
prod_kubeconfig="${repo_root}/terraform/environments/prod/kubeconfig-local-platform-prod"
dev_port="$(KUBECONFIG="$dev_kubeconfig" kubectl -n gateway-api-examples get svc demo-gateway-istio -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)"
prod_port="$(KUBECONFIG="$prod_kubeconfig" kubectl -n gateway-api-examples get svc demo-gateway-istio -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)"

cat <<EOF

==> Platform is up.
  curl https://template-test-1.dev.platform.local:${dev_port}/
  curl https://template-test-1.prod.platform.local:${prod_port}/
EOF
