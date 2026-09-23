#!/usr/bin/env bash
# Milestone 5, Phase 3: one-time host-level setup for *.{dev,prod}.platform.local
# resolution -- host-level, not Terraform/GitOps-managed, for the same reason
# scripts/setup-laptop-exporter.sh (Phase 5) will be: this configures the Mac
# itself, not any cluster.
#
# Requires docker-mac-net-connect already running (brew services start
# docker-mac-net-connect, as root -- it needs to create a TUN device, a
# plain `brew services start` without sudo fails with "operation not
# permitted") so the Mac can actually route to the Gateway IPs this
# resolves to; DNS alone doesn't help if nothing can reach the resolved
# address.
#
# Gateway IPs are read live from each cluster (not hardcoded) but WILL
# change if a cluster is ever torn down and recreated -- MetalLB's IPAM
# state resets with the cluster, same caveat already documented for
# scripts/sync-runner-creds.sh's container IPs. Re-run this script after
# recreating dev or prod.
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

dev_ip="$(KUBECONFIG="$dev_kubeconfig" kubectl -n gateway-api-examples get gateway demo-gateway -o jsonpath='{.status.addresses[0].value}')"
prod_ip="$(KUBECONFIG="$prod_kubeconfig" kubectl -n gateway-api-examples get gateway demo-gateway -o jsonpath='{.status.addresses[0].value}')"

if [ -z "$dev_ip" ] || [ -z "$prod_ip" ]; then
  echo "error: could not read the Gateway's assigned IP from dev and/or prod -- is MetalLB up and the Gateway Programmed?" >&2
  exit 1
fi

echo "==> dev.platform.local  -> ${dev_ip}"
echo "==> prod.platform.local -> ${prod_ip}"

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
# `ifconfig lo0 alias`, done below as part of the one sudo step.
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

cat <<EOF

==> dnsmasq configured. Port 53 needs root, so the remaining steps all
need sudo -- run these yourself (one block, in order):

  sudo ifconfig lo0 alias 127.0.0.2 up
  sudo brew services start dnsmasq
  sudo mkdir -p /etc/resolver
  sudo tee /etc/resolver/platform.local >/dev/null <<RESOLVER
nameserver 127.0.0.2
RESOLVER

The loopback alias doesn't survive a reboot -- re-run
'sudo ifconfig lo0 alias 127.0.0.2 up' (and restart dnsmasq) if you
reboot and DNS stops resolving. If dnsmasq was already running from an
earlier attempt, use 'sudo brew services restart dnsmasq' instead so it
picks up this config.

Verify once done:
  scutil --dns | grep -A3 platform.local
  dig template-test-1.dev.platform.local
EOF
