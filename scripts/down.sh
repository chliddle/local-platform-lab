#!/usr/bin/env bash
# Tears down all three clusters in one command -- the reverse of
# scripts/up.sh's cluster-bootstrap steps.
#
# Deliberately leaves the host-level setup (docker-mac-net-connect,
# dnsmasq, /etc/resolver/platform.local, the trusted CAs) in place: it's
# inert with no clusters running, reusable on the next 'make up' without
# re-prompting for sudo/Touch ID every single cycle, and harmless to leave
# installed (dnsmasq will just have stale IPs until the next 'make up'
# refreshes them, and CA trust is a public-cert trust decision, not a
# credential). Use 'make down-full' instead if you want that removed too.
#
# Usage: scripts/down.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> [1/3] Tearing down prod cluster"
"${repo_root}/scripts/teardown.sh" prod

echo "==> [2/3] Tearing down dev cluster"
"${repo_root}/scripts/teardown.sh" dev

echo "==> [3/3] Tearing down management cluster"
"${repo_root}/scripts/teardown.sh" management

echo "==> Platform is down. Host-level setup (docker-mac-net-connect, dnsmasq, CA trust) left in place -- see this script's header if you want it fully removed."
