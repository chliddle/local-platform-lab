#!/usr/bin/env bash
# Brings up the whole platform in one command: all three clusters, the
# cross-cluster credential sync ARC's runner needs (Milestone 4), and the
# host-level setup Milestone 5's local HTTPS access needs. Idempotent --
# safe to re-run (each step it calls is).
#
# Clusters bootstrap one at a time, and bootstrap.sh now blocks until every
# Application in that cluster is Synced+Healthy before returning -- not
# just until Argo CD itself is up. Confirmed live (Milestone 5, Phase 4)
# this matters: bootstrapping all three concurrently let their reconcile
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

echo "==> [1/8] Bootstrapping management cluster (waits for full health)"
"${repo_root}/scripts/bootstrap.sh" management

echo "==> [2/8] Bootstrapping dev cluster (waits for full health)"
"${repo_root}/scripts/bootstrap.sh" dev

echo "==> [3/8] Bootstrapping prod cluster (waits for full health)"
"${repo_root}/scripts/bootstrap.sh" prod

echo "==> [4/8] Syncing dev/prod Argo CD read credentials into management"
"${repo_root}/scripts/sync-runner-creds.sh"

echo "==> [5/8] Syncing cross-cluster monitoring targets (CAs, probe targets, OTLP endpoint)"
"${repo_root}/scripts/sync-monitoring-targets.sh"

echo "==> [6/8] Checking Mac -> cluster network routing"
"${repo_root}/scripts/setup-mac-networking.sh"

echo "==> [7/8] Setting up local DNS (*.dev.platform.local, *.prod.platform.local)"
"${repo_root}/scripts/setup-local-dns.sh"

echo "==> [8/8] Trusting both clusters' local CAs"
"${repo_root}/scripts/trust-local-ca.sh"

cat <<'EOF'

==> Platform is up.
  curl https://template-test-1.dev.platform.local/
  curl https://template-test-1.prod.platform.local/
EOF
