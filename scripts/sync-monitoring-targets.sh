#!/usr/bin/env bash
# Milestone 5, Phase 4: wires up the cross-cluster parts of the monitoring
# stack that can't be plain GitOps, because they need a *live* value only
# this Mac's Docker daemon and the running clusters know: container IPs on
# the shared kind Docker network, an auto-assigned NodePort, and freshly
# generated per-cluster CA certs. Same reasoning, same "script bridges
# ephemeral infra into GitOps-managed clusters" pattern as
# scripts/sync-runner-creds.sh (Milestone 4) -- see that script and
# CLAUDE.md's "Lessons Learned" for why this can't be Terraform/GitOps.
#
# Metrics/logs/traces themselves need no cross-cluster wiring here beyond
# the OTLP endpoint below -- every cluster's OTel Collector pushes
# everything to management over one NodePort, replacing the older
# Prometheus pull-scrape design (no more per-cluster NodePort services or
# scrape-config secrets to keep in sync).
#
# Writes:
#   management cluster, namespace monitoring:
#     - Secret blackbox-target-cas: dev/prod root CA certs, mounted into
#       blackbox-exporter so it can validate *.platform.local's TLS chain
#       without -k/insecure_skip_verify.
#     - Probe dev-template-test-1 / prod-template-test-1: each cluster's
#       Gateway IP as a static blackbox probe target.
#   dev and prod clusters, namespace monitoring:
#     - ConfigMap management-endpoints: management's container IP + the
#       central OTel Collector's NodePort, consumed by each cluster's
#       OTel Collector agent (platform/gitops-platform-apps/
#       otel-collector-agent.yaml) via envFrom.
#
# Container IPs, the NodePort, and CA certs are NOT stable across `kind
# delete`/`create` -- re-run this after recreating any cluster. Called
# automatically by scripts/up.sh.
#
# Usage: scripts/sync-monitoring-targets.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

dev_kubeconfig="${repo_root}/terraform/environments/dev/kubeconfig-local-platform-dev"
prod_kubeconfig="${repo_root}/terraform/environments/prod/kubeconfig-local-platform-prod"
mgmt_kubeconfig="${repo_root}/terraform/environments/management/kubeconfig-local-platform-management"

for kc in "$dev_kubeconfig" "$prod_kubeconfig" "$mgmt_kubeconfig"; do
  if [ ! -f "$kc" ]; then
    echo "error: kubeconfig not found at ${kc}. Run 'make up' (or the relevant 'make bootstrap*') first." >&2
    exit 1
  fi
done

container_ip() {
  docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$1"
}

echo "==> Resolving management's container IP on the kind Docker network"
mgmt_ip="$(container_ip local-platform-management-control-plane)"
echo "    management=${mgmt_ip}"

# Waits for the central OTel Collector's NodePort to be assigned -- Argo CD
# reconciles this chart asynchronously (same reasoning as
# setup-local-dns.sh's Gateway wait loop), so a just-bootstrapped cluster
# may not have it yet.
echo "==> Waiting for management's central OTel Collector NodePort"
otel_port="" deadline=$((SECONDS + 180))
while [ -z "$otel_port" ]; do
  otel_port="$(KUBECONFIG="$mgmt_kubeconfig" kubectl -n monitoring get svc otel-collector \
    -o jsonpath='{.spec.ports[?(@.name=="otlp")].nodePort}' 2>/dev/null || true)"
  if [ -n "$otel_port" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "error: timed out waiting for monitoring/otel-collector's otlp NodePort." >&2
    exit 1
  fi
  sleep 10
done
echo "    otel-collector=${otel_port}"

echo "==> Waiting for dev/prod Gateway IP"
dev_gw_ip="" prod_gw_ip="" deadline=$((SECONDS + 180))
while [ -z "$dev_gw_ip" ] || [ -z "$prod_gw_ip" ]; do
  dev_gw_ip="$(KUBECONFIG="$dev_kubeconfig" kubectl -n gateway-api-examples get gateway demo-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  prod_gw_ip="$(KUBECONFIG="$prod_kubeconfig" kubectl -n gateway-api-examples get gateway demo-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  if [ -n "$dev_gw_ip" ] && [ -n "$prod_gw_ip" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "error: timed out waiting for dev/prod's Gateway to be Programmed." >&2
    exit 1
  fi
  sleep 10
done
echo "    dev=${dev_gw_ip} prod=${prod_gw_ip}"

ca_dir="$(mktemp -d)"
trap 'rm -rf "$ca_dir"' EXIT
KUBECONFIG="$dev_kubeconfig" kubectl -n cert-manager get secret dev-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d >"${ca_dir}/dev-ca.crt"
KUBECONFIG="$prod_kubeconfig" kubectl -n cert-manager get secret prod-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d >"${ca_dir}/prod-ca.crt"

echo "==> Writing dev/prod root CAs into management for blackbox-exporter"
KUBECONFIG="$mgmt_kubeconfig" kubectl -n monitoring create secret generic blackbox-target-cas \
  --from-file="dev-ca.crt=${ca_dir}/dev-ca.crt" \
  --from-file="prod-ca.crt=${ca_dir}/prod-ca.crt" \
  --dry-run=client -o yaml \
  | KUBECONFIG="$mgmt_kubeconfig" kubectl apply -f -

echo "==> Writing blackbox Probes for dev/prod's Gateway"
KUBECONFIG="$mgmt_kubeconfig" kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: dev-template-test-1
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  jobName: blackbox-dev-template-test-1
  interval: 120s
  module: https_dev
  prober:
    url: blackbox-exporter:9115
  targets:
    staticConfig:
      static:
        - "https://${dev_gw_ip}/"
      labels:
        cluster: dev
---
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: prod-template-test-1
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  jobName: blackbox-prod-template-test-1
  interval: 120s
  module: https_prod
  prober:
    url: blackbox-exporter:9115
  targets:
    staticConfig:
      static:
        - "https://${prod_gw_ip}/"
      labels:
        cluster: prod
EOF

echo "==> Writing management's endpoint into dev/prod for the OTel Collector agent"
for env_kubeconfig in "$dev_kubeconfig" "$prod_kubeconfig"; do
  KUBECONFIG="$env_kubeconfig" kubectl -n monitoring create configmap management-endpoints \
    --from-literal="OTLP_ENDPOINT=${mgmt_ip}:${otel_port}" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$env_kubeconfig" kubectl apply -f -
done

echo ""
echo "==> Done. If the OTel Collector agent was already running, restart it to pick up the change:"
echo "  kubectl --kubeconfig ${dev_kubeconfig} -n monitoring rollout restart daemonset/otel-collector-agent-agent"
echo "  kubectl --kubeconfig ${prod_kubeconfig} -n monitoring rollout restart daemonset/otel-collector-agent-agent"
