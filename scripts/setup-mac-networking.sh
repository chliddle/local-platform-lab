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

# Two genuinely distinct failure modes confirmed live, not the same fix --
# check which one this actually is instead of always printing the same
# generic instructions (confirmed live those are useless, and misleading,
# for the second case: telling someone to `sudo brew services start` a
# service that's already correctly running as root, when the real problem
# is a stuck WireGuard handshake, just wastes their time). `brew services
# list`'s own status column turned out NOT to be a reliable signal here
# (confirmed live: it reported "none" immediately after `brew services
# start` itself reported "already started" as root) -- the log is: a
# repeated "Handshake did not complete" line can only appear once the
# process has already gotten past TUN-device creation (root privilege
# confirmed), so its presence alone distinguishes the two cases.
stderr_log="$(brew --prefix)/var/log/docker-mac-net-connect/std_error.log"
stdout_log="$(brew --prefix)/var/log/docker-mac-net-connect/std_out.log"
# tail, not the whole file: this log is never rotated/cleared, so old
# errors from a previous, unrelated failure linger forever otherwise --
# confirmed live checking only the last handful of lines is what actually
# reflects current state.
if tail -n 20 "$stdout_log" 2>/dev/null | grep -q "Handshake did not complete"; then
  cat <<EOF
==> Not reachable, but docker-mac-net-connect IS already running as root
-- this is a STUCK WIREGUARD HANDSHAKE, not the permission problem (its
own log, ${stdout_log}, shows repeated "Handshake did not complete...
retrying"). Confirmed live: this happens when Docker Desktop and
docker-mac-net-connect were started/restarted at different times during a
long session -- each side generates its own WireGuard keypair at startup,
so one side ends up holding the other's now-stale public key and they can
never shake hands again.

Fix: restart BOTH together, Docker Desktop first, then this service:

  sudo brew services stop docker-mac-net-connect
  # quit and reopen Docker Desktop (or: killall Docker && open -a Docker),
  # wait for it to fully come back up, THEN:
  sudo brew services start docker-mac-net-connect

Verify once done (re-run this script, or manually):
  curl -sk https://172.18.0.2:6443    # any live cluster's control-plane IP
EOF
else
  cat <<EOF
==> Not reachable yet. docker-mac-net-connect needs to run as a root
background service (it creates a TUN device, which needs root) -- run
this yourself:

  sudo brew services start docker-mac-net-connect

A PLAIN (non-sudo) \`brew services start\` will appear to succeed but
actually fails: it registers as a user-level LaunchAgent instead of a
root LaunchDaemon, which can't create the TUN device it needs
("operation not permitted") -- confirmed live via
${stderr_log}. If you've already hit that, clean it up first:

  brew services stop docker-mac-net-connect
  sudo brew services start docker-mac-net-connect

Verify once done (re-run this script, or manually):
  curl -sk https://172.18.0.2:6443    # any live cluster's control-plane IP
EOF
fi
exit 1
