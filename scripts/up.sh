#!/usr/bin/env bash
# Brings up the whole platform in one command: all three clusters, the
# cross-cluster credential sync ARC's runner needs (Milestone 4), and the
# host-level setup Milestone 5's local HTTPS access needs. Idempotent --
# safe to re-run (each step it calls is).
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

echo "==> [1/7] Bootstrapping management cluster"
"${repo_root}/scripts/bootstrap.sh" management

echo "==> [2/7] Bootstrapping dev cluster"
"${repo_root}/scripts/bootstrap.sh" dev

echo "==> [3/7] Bootstrapping prod cluster"
"${repo_root}/scripts/bootstrap.sh" prod

echo "==> [4/7] Syncing dev/prod Argo CD read credentials into management"
"${repo_root}/scripts/sync-runner-creds.sh"

echo "==> [5/7] Checking Mac -> cluster network routing"
"${repo_root}/scripts/setup-mac-networking.sh"

echo "==> [6/7] Setting up local DNS (*.dev.platform.local, *.prod.platform.local)"
"${repo_root}/scripts/setup-local-dns.sh"

echo "==> [7/7] Trusting both clusters' local CAs"
"${repo_root}/scripts/trust-local-ca.sh"

cat <<'EOF'

==> Platform is up.
  curl https://template-test-1.dev.platform.local/
  curl https://template-test-1.prod.platform.local/
EOF
