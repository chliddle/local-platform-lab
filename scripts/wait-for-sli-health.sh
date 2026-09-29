#!/usr/bin/env bash
# Complements wait-for-argocd-health.sh: Argo CD Application health only
# proves the workload's own resources (Deployment/Rollout/Pod) look right
# -- it does NOT prove real requests actually succeed. Milestone 6's own
# FAULT_ERROR_RATE fault injection exists precisely to demonstrate that
# gap (breaks real traffic while /health and /ready stay green), so this
# script generates a short burst of real traffic and checks the resulting
# SLIs: synthetic probe success (blackbox), HTTP error rate (Prometheus
# app metrics), and HTTPRoute routing status -- the same three signals the
# user asked to gate prod promotion on.
#
# Per namespace, each check is best-effort/skippable rather than a hard
# requirement, since not every app has every signal wired up (e.g.
# blackbox probes are currently hand-provisioned per app, per
# scripts/sync-monitoring-targets.sh's own comment) -- a missing signal is
# not treated as a failure, only a present-and-bad one is. This keeps the
# gate meaningful for template-test-1 today without hard-blocking a future
# app that hasn't had synthetic monitoring set up yet.
#
# Must run on a pod with network reach to Prometheus and to the target
# Services directly (in-cluster) -- meant for platform-runners, same as
# wait-for-argocd-health.sh.
#
# Usage: scripts/wait-for-sli-health.sh <service-name> <namespace> [namespace...]
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <service-name> <namespace> [namespace...]" >&2
  exit 2
fi

service_name="$1"
shift
namespaces="$*"

prom="http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
traffic_seconds=20
max_error_rate=0.01 # 1% -- allows for one transient blip in ~100 requests, not a real break

prom_query() {
  curl -fsSL --data-urlencode "query=$1" "${prom}/api/v1/query"
}

failures=""

for ns in $namespaces; do
  echo "== ${ns} =="

  echo "Generating ~${traffic_seconds}s of real traffic against http://${service_name}.${ns}.svc.cluster.local:8080/"
  end=$((SECONDS + traffic_seconds))
  while [ "$SECONDS" -lt "$end" ]; do
    curl -s -o /dev/null -m 3 "http://${service_name}.${ns}.svc.cluster.local:8080/" || true
    sleep 0.2
  done

  # Blackbox synthetic probe: skip (not a failure) if this app has no
  # probe configured at all -- only a present, failing probe blocks.
  probe_result=$(prom_query "probe_success{job=\"blackbox-${ns}\"}")
  probe_count=$(echo "$probe_result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['data']['result']))")
  if [ "$probe_count" -gt 0 ]; then
    probe_value=$(echo "$probe_result" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['result'][0]['value'][1])")
    if [ "$probe_value" != "1" ]; then
      failures="${failures}${ns}: blackbox probe_success=${probe_value} (expected 1)"$'\n'
    else
      echo "blackbox probe: OK"
    fi
  else
    echo "blackbox probe: not configured for ${ns}, skipping"
  fi

  # HTTP error rate over the traffic window just generated. Requires at
  # least one real sample -- an empty/zero-total result means no traffic
  # data exists yet (not necessarily a failure) and is skipped rather than
  # treated as 0% error, to avoid a false pass on missing data.
  total=$(prom_query "sum(increase(http_requests_total{namespace=\"${ns}\"}[2m])) or vector(0)" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['result'][0]['value'][1])")
  errors=$(prom_query "sum(increase(http_requests_total{namespace=\"${ns}\", status=~\"5..\"}[2m])) or vector(0)" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['result'][0]['value'][1])")
  if python3 -c "exit(0 if float('$total') > 0 else 1)"; then
    error_rate=$(python3 -c "print(float('$errors') / float('$total'))")
    if python3 -c "exit(0 if float('$error_rate') > $max_error_rate else 1)"; then
      failures="${failures}${ns}: HTTP error rate ${error_rate} (${errors}/${total} requests) exceeds ${max_error_rate}"$'\n'
    else
      echo "HTTP error rate: OK (${errors}/${total})"
    fi
  else
    echo "HTTP metrics: no traffic data for ${ns}, skipping"
  fi

  # HTTPRoute routing status. Skip (not a failure) if this app has no
  # HTTPRoute at all -- e.g. template-test-1-canary routes through a
  # dedicated Istio VirtualService instead (see CLAUDE.md's Milestone 6
  # note), which has no equivalent status.conditions surface to check the
  # same way. Convention: HTTPRoute name == namespace, matching every
  # HTTPRoute onboarded so far.
  if kubectl --server=https://kubernetes.default.svc --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    -n gateway-api-examples get httproute "$ns" >/dev/null 2>&1; then
    conditions=$(kubectl --server=https://kubernetes.default.svc --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
      -n gateway-api-examples get httproute "$ns" -o jsonpath='{.status.parents[*].conditions}')
    # An empty result here (no parents/conditions at all -- e.g. a Gateway
    # ref that no longer resolves) is itself a broken-routing signal, not
    # something to skip: treated as "not accepted" below rather than
    # failing the python parse.
    if [ -z "$conditions" ]; then
      not_accepted=1
    else
      not_accepted=$(echo "$conditions" | python3 -c "
import json,sys
conds = json.load(sys.stdin)
bad = [c for c in conds if c['type'] in ('Accepted','ResolvedRefs') and c['status'] != 'True']
print(len(bad))
")
    fi
    if [ "$not_accepted" != "0" ]; then
      failures="${failures}${ns}: HTTPRoute ${ns} not Accepted/ResolvedRefs: ${conditions}"$'\n'
    else
      echo "HTTPRoute: OK"
    fi
  else
    echo "HTTPRoute: none named ${ns} in gateway-api-examples, skipping"
  fi
done

if [ -n "$failures" ]; then
  echo "::error::SLI health check failed:"
  echo "$failures"
  exit 1
fi

echo "All SLI checks passed for [$namespaces]."
