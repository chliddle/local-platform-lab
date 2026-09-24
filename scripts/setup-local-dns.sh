#!/usr/bin/env bash
# Milestone 5, Phase 3: one-time (well, one-time-per-cluster-recreation)
# host-level setup for *.{dev,prod}.platform.local resolution --
# host-level, not Terraform/GitOps-managed, for the same reason
# scripts/setup-laptop-exporter.sh (Phase 5) will be: this configures the
# Mac itself, not any cluster.
#
# Requires scripts/setup-mac-networking.sh already run: DNS alone doesn't
# help if the Mac can't route to the resolved address (by default, Docker
# Desktop for Mac doesn't route the host to containers' bridge networks --
# see that script for the full explanation).
#
# Gateway IPs are read live from each cluster (not hardcoded) but WILL
# change if a cluster is ever torn down and recreated -- Kind assigns a
# fresh container IP each time, same caveat already documented for
# scripts/sync-runner-creds.sh's container IPs. Re-run this script after
# recreating dev or prod.
#
# This resolves *.platform.local to each cluster's own Kind node
# container IP directly, not a LoadBalancer IP -- Milestone 6 dropped
# MetalLB (see platform/gateway-api/examples/gateway.yaml's comment) in
# favor of Istio's native NodePort exposure. DNS can't encode a port, so
# reaching anything through this now needs an explicit `:<nodePort>`
# suffix -- see docs/local-https-access.md for the live-read nodePort and
# full curl examples. This script prints each cluster's nodePort below for
# convenience, but doesn't (can't) bake it into the DNS entry itself.
#
# Runs with real sudo calls, not printed instructions -- meant to be run
# directly in your own terminal (interactive password/Touch ID prompts
# aren't scriptable through anything else), as part of `make up` or on
# its own.
#
# Usage: scripts/setup-local-dns.sh
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

echo "==> Checking the Mac can reach the kind Docker network"
dev_node_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' local-platform-dev-control-plane 2>/dev/null || true)"
if [ -z "$dev_node_ip" ] || ! curl -sk -m 2 -o /dev/null "https://${dev_node_ip}:6443" 2>/dev/null; then
  echo "error: can't reach the dev cluster's node directly. Run scripts/setup-mac-networking.sh first." >&2
  exit 1
fi

# The Gateway's Service may not be provisioned yet on a just-bootstrapped
# cluster (Argo CD reconciles asynchronously -- see scripts/bootstrap.sh)
# -- retry rather than fail immediately.
echo "==> Waiting for both clusters' Gateway Service to get a NodePort (up to 3 min)"
dev_ip=""
prod_ip=""
dev_port=""
prod_port=""
deadline=$((SECONDS + 180))
while [ -z "$dev_ip" ] || [ -z "$prod_ip" ] || [ -z "$dev_port" ] || [ -z "$prod_port" ]; do
  dev_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' local-platform-dev-control-plane 2>/dev/null || true)"
  prod_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' local-platform-prod-control-plane 2>/dev/null || true)"
  dev_port="$(KUBECONFIG="$dev_kubeconfig" kubectl -n gateway-api-examples get svc demo-gateway-istio -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)"
  prod_port="$(KUBECONFIG="$prod_kubeconfig" kubectl -n gateway-api-examples get svc demo-gateway-istio -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)"
  if [ -n "$dev_ip" ] && [ -n "$prod_ip" ] && [ -n "$dev_port" ] && [ -n "$prod_port" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "error: timed out waiting for the Gateway Service to be provisioned on dev and/or prod." >&2
    exit 1
  fi
  sleep 10
done

echo "==> dev.platform.local  -> ${dev_ip}  (HTTPS nodePort: ${dev_port})"
echo "==> prod.platform.local -> ${prod_ip}  (HTTPS nodePort: ${prod_port})"

if ! command -v dnsmasq >/dev/null 2>&1; then
  echo "==> Installing dnsmasq"
  brew install dnsmasq
fi

# 127.0.0.2, not 127.0.0.1: confirmed via Homebrew's own dnsmasq install
# caveat and verified live -- macOS's /etc/resolver/<domain> mechanism
# silently ignores a custom `port` directive when the nameserver is
# 127.0.0.1, so a non-53 port on the loopback address doesn't actually
# work despite dnsmasq itself running fine. A second loopback address on
# the standard port 53 is the documented, reliable way to scope a
# resolver override to one domain. 127.0.0.2 isn't usable out of the box
# either, though (verified live: 100% ping loss until aliased) -- needs
# `ifconfig lo0 alias`, done below.
dnsmasq_conf="$(brew --prefix)/etc/dnsmasq.conf"

echo "==> Writing ${dnsmasq_conf}"
cat >"$dnsmasq_conf" <<EOF
# Managed by scripts/setup-local-dns.sh -- re-run that script rather than
# hand-editing this file, it gets overwritten.
port=53
listen-address=127.0.0.2
bind-interfaces
address=/dev.platform.local/${dev_ip}
address=/prod.platform.local/${prod_ip}
EOF

echo "==> The rest needs root (loopback alias + binding port 53) -- you may be prompted for your password."
sudo -v

sudo ifconfig lo0 alias 127.0.0.2 up
sudo brew services restart dnsmasq
sudo mkdir -p /etc/resolver
sudo tee /etc/resolver/platform.local >/dev/null <<RESOLVER
nameserver 127.0.0.2
RESOLVER

cat <<EOF

==> Done. The loopback alias doesn't survive a reboot -- re-run this
script (or 'sudo ifconfig lo0 alias 127.0.0.2 up' + 'sudo brew services
restart dnsmasq') if you reboot and DNS stops resolving.

NodePorts are NOT stable across a cluster recreate -- if you tear down and
rebuild dev/prod, re-run this script and use the newly printed port.

Verify:
  dscacheutil -q host -a name template-test-1.dev.platform.local
  curl -k https://template-test-1.dev.platform.local:${dev_port}/
EOF
