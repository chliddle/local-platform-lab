#!/usr/bin/env bash
# Milestone 5, Phase 3: prerequisite for scripts/setup-local-dns.sh and any
# other direct Mac -> cluster-network access (curling a Gateway IP, etc).
#
# By default, Docker Desktop for Mac does NOT route the host's own network
# stack to its containers' bridge networks (e.g. the `kind` network Kind's
# clusters share) -- verified live this session: no route, no interface,
# a direct curl to a live container IP just times out, even though
# general internet egress works fine. This is different from Docker on
# native Linux, where the bridge lives directly on the host's own network
# stack. docker-mac-net-connect (a WireGuard-based bridge) closes that gap.
#
# Host-level, not Terraform/GitOps-managed, same category as Docker
# Desktop itself -- this configures the Mac, not any cluster.
#
# Usage: scripts/setup-mac-networking.sh
set -euo pipefail

if ! command -v docker-mac-net-connect >/dev/null 2>&1 && [ ! -x /opt/homebrew/opt/docker-mac-net-connect/bin/docker-mac-net-connect ]; then
  echo "==> Installing docker-mac-net-connect"
  brew install chipmk/tap/docker-mac-net-connect
fi

echo "==> Checking whether the Mac can already reach the kind Docker network"
test_ip=""
for kc in \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/terraform/environments/dev/kubeconfig-local-platform-dev" \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/terraform/environments/prod/kubeconfig-local-platform-prod"; do
  if [ -f "$kc" ]; then
    ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' \
      "$(KUBECONFIG="$kc" kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null | sed 's/^kind-//')-control-plane" 2>/dev/null || true)"
    if [ -n "$ip" ]; then
      test_ip="$ip"
      break
    fi
  fi
done

if [ -n "$test_ip" ] && curl -sk -m 2 -o /dev/null "https://${test_ip}:6443" 2>/dev/null; then
  echo "==> Already working -- the Mac can reach ${test_ip} directly. Nothing more to do."
  exit 0
fi

cat <<'EOF'
==> Not reachable yet. docker-mac-net-connect needs to run as a root
background service (it creates a TUN device, which needs root) -- run
this yourself:

  sudo brew services start docker-mac-net-connect

A PLAIN (non-sudo) `brew services start` will appear to succeed but
actually fails: it registers as a user-level LaunchAgent instead of a
root LaunchDaemon, which can't create the TUN device it needs
("operation not permitted") -- confirmed live via
/opt/homebrew/var/log/docker-mac-net-connect/std_error.log. If you've
already hit that, clean it up first:

  brew services stop docker-mac-net-connect
  sudo brew services start docker-mac-net-connect

Verify once done (re-run this script, or manually):
  curl -sk https://172.18.0.2:6443    # any live cluster's control-plane IP
EOF
