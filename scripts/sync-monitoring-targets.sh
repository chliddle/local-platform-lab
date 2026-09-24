#!/usr/bin/env bash
# Wires up the one part of dev's monitoring stack that can't be plain
# GitOps: blackbox-exporter needs this cluster's own root CA cert (so it
# can validate *.platform.local's TLS chain without -k/
# insecure_skip_verify) and this cluster's own Gateway IP as its probe
# target -- both live values only a script running against the real,
# already-reconciling cluster can see. Same "script bridges ephemeral
# infra into GitOps-managed clusters" pattern as scripts/sync-runner-
# creds.sh -- see that script for why this can't be Terraform/GitOps.
#
# dev only: blackbox-exporter (and the observability stack its Probe
# result feeds into) doesn't run on prod -- confirmed live it doesn't fit
# in this VM's 7.65GiB alongside everything else both clusters already
# run (see gitops/dev/platform/kube-prometheus-stack.yaml's comment).
#
# The CA cert just needs copying from cert-manager's namespace into
# monitoring's (Secrets don't cross namespaces on their own).
#
# Writes, in dev, namespace monitoring:
#   - Secret blackbox-target-ca: dev's own root CA cert, mounted into
#     blackbox-exporter (gitops/dev/platform/blackbox-exporter.yaml).
#   - Probe template-test-1: dev's own Gateway IP as the static blackbox
#     probe target.
#
# The Gateway IP is NOT stable across `kind delete`/`create` -- re-run this
# after recreating dev. Called automatically by scripts/bootstrap.sh.
#
# Usage: scripts/sync-monitoring-targets.sh <dev|prod>
set -euo pipefail

env_name="${1:?usage: sync-monitoring-targets.sh <dev|prod>}"
case "$env_name" in
  dev | prod) ;;
  *)
    echo "error: unknown environment '${env_name}' (expected dev or prod)" >&2
    exit 1
    ;;
esac

if [ "$env_name" != "dev" ]; then
  echo "==> ${env_name} runs no observability stack -- nothing to sync."
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/terraform/environments/${env_name}/kubeconfig-local-platform-${env_name}"

if [ ! -f "$kubeconfig" ]; then
  echo "error: kubeconfig not found at ${kubeconfig}. Run 'make bootstrap' first." >&2
  exit 1
fi

echo "==> [${env_name}] Waiting for the root CA Secret (cert-manager-ca.yaml)"
deadline=$((SECONDS + 180))
while ! KUBECONFIG="$kubeconfig" kubectl -n cert-manager get secret "${env_name}-root-ca-secret" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "error: timed out waiting for cert-manager/${env_name}-root-ca-secret." >&2
    exit 1
  fi
  sleep 10
done

echo "==> [${env_name}] Waiting for the Gateway IP"
gw_ip="" deadline=$((SECONDS + 180))
while [ -z "$gw_ip" ]; do
  gw_ip="$(KUBECONFIG="$kubeconfig" kubectl -n gateway-api-examples get gateway demo-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  if [ -n "$gw_ip" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "error: timed out waiting for ${env_name}'s Gateway to be Programmed." >&2
    exit 1
  fi
  sleep 10
done
echo "    ${env_name} gateway=${gw_ip}"

ca_file="$(mktemp)"
trap 'rm -f "$ca_file"' EXIT
KUBECONFIG="$kubeconfig" kubectl -n cert-manager get secret "${env_name}-root-ca-secret" -o jsonpath='{.data.ca\.crt}' | base64 -d >"$ca_file"

# The monitoring namespace is normally created by Argo CD (CreateNamespace=true
# on whichever observability Application syncs first), but that's a race this
# script can't depend on winning -- confirmed live it loses often enough to
# matter (this Secret write 404ing with "namespaces monitoring not found" on
# a truly fresh cluster). Idempotent and harmless if Argo CD gets there first.
KUBECONFIG="$kubeconfig" kubectl create namespace monitoring --dry-run=client -o yaml \
  | KUBECONFIG="$kubeconfig" kubectl apply -f -

echo "==> [${env_name}] Copying the root CA into monitoring for blackbox-exporter"
KUBECONFIG="$kubeconfig" kubectl -n monitoring create secret generic blackbox-target-ca \
  --from-file="ca.crt=${ca_file}" \
  --dry-run=client -o yaml \
  | KUBECONFIG="$kubeconfig" kubectl apply -f -

echo "==> [${env_name}] Writing the blackbox Probe for this cluster's Gateway"
KUBECONFIG="$kubeconfig" kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: template-test-1
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  jobName: blackbox-template-test-1
  interval: 120s
  module: https
  prober:
    url: blackbox-exporter:9115
  targets:
    staticConfig:
      static:
        - "https://${gw_ip}/"
      labels:
        cluster: ${env_name}
EOF

echo ""
echo "==> [${env_name}] Done. If blackbox-exporter was already running, restart it to pick up the CA:"
echo "  kubectl --kubeconfig ${kubeconfig} -n monitoring rollout restart deployment/blackbox-exporter"
