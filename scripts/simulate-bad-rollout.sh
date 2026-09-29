#!/usr/bin/env bash
# Milestone 6, Phase 4: pushes the same synthetic fault
# (internal/middleware/fault.go in the template-test-1 repo) to all three
# dev deployment-strategy variants at once, then generates real,
# sustained traffic against all three so the comparison is actually
# visible live -- on the Progressive Delivery dashboard, and to Argo
# Rollouts' own canary AnalysisTemplate, which needs real samples to
# evaluate, not just a config change.
#
# A pure GitOps config change, not an image rebuild -- FAULT_ERROR_RATE is
# read at container startup (see that middleware's own comment), so
# bumping it is exactly the same kind of change as ENVIRONMENT already is:
# commit, push, Argo CD/Rollouts rolls a new ReplicaSet.
#
# Traffic generation runs as an in-cluster Job (not curl from this Mac
# through the Gateway) deliberately: it only needs to prove the APP's own
# behavior differs across variants (visible via http_requests_total,
# scraped directly pod-to-pod by the OTel Collector -- see
# gitops/dev/platform/otel-collector.yaml), which has nothing to do with
# external routing. Decouples this script from the Gateway/local-DNS/
# Mac-networking stack entirely, and from each variant's own rollout
# timing: the Job starts generating traffic immediately, in the
# background, for the full window, regardless of how long any individual
# Rollout's steps take to progress.
#
# dev-bluegreen's fault will NOT reach real traffic on its own -- that's
# the point: autoPromotionEnabled: false means the new (faulty)
# ReplicaSet only ever serves the previewService until a human runs
# `kubectl argo rollouts promote`. Compare its previewService against
# rolling/canary's live behavior; don't expect its dashboard line to move
# unless you promote it yourself.
#
# Usage:
#   scripts/simulate-bad-rollout.sh <rate> [duration_seconds]   # e.g. 0.4 180
#   scripts/simulate-bad-rollout.sh revert                      # back to 0, no traffic
set -euo pipefail

rate="${1:?usage: simulate-bad-rollout.sh <rate 0.0-1.0 | revert> [duration_seconds]}"
duration="${2:-180}"

if [ "$rate" = "revert" ]; then
  rate="0"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_repo="$(cd "${repo_root}/../template-test-1" && pwd)"
kubeconfig="${repo_root}/terraform/environments/dev/kubeconfig-local-platform-dev"

if [ ! -f "$kubeconfig" ]; then
  echo "error: dev kubeconfig not found at ${kubeconfig}. Run 'make bootstrap' first." >&2
  exit 1
fi
if [ ! -d "${app_repo}/.git" ]; then
  echo "error: expected a sibling checkout of template-test-1 at ${app_repo} (this script edits its deploy manifests directly, same layout this whole platform assumes)." >&2
  exit 1
fi

# Replaces exactly the value line immediately following the
# FAULT_ERROR_RATE name line -- awk, not a blind sed on `value: "0"`,
# since that string alone isn't unique enough in these files (other env
# vars have their own value lines too). Preserves every comment and every
# other line byte-for-byte.
set_fault_rate() {
  local file="$1"
  awk -v rate="$rate" '
    /- name: FAULT_ERROR_RATE/ { print; found=1; next }
    found && /value:/ { sub(/value: ".*"/, "value: \"" rate "\""); found=0; print; next }
    { print }
  ' "$file" >"${file}.tmp"
  mv "${file}.tmp" "$file"
}

echo "==> [1/3] Starting the in-cluster traffic generator (${duration}s, all three variants)"
KUBECONFIG="$kubeconfig" kubectl -n default delete job simulate-bad-rollout-traffic --ignore-not-found >/dev/null 2>&1
KUBECONFIG="$kubeconfig" kubectl apply -f - <<EOF >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: simulate-bad-rollout-traffic
  namespace: default
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: traffic
          image: curlimages/curl:8.11.0
          command:
            - sh
            - -c
            - |
              end=\$(( \$(date +%s) + ${duration} ))
              while [ "\$(date +%s)" -lt "\$end" ]; do
                curl -s -o /dev/null http://template-test-1.template-test-1-rolling.svc.cluster.local:8080/ || true
                curl -s -o /dev/null http://template-test-1.template-test-1-bluegreen.svc.cluster.local:8080/ || true
                curl -s -o /dev/null http://template-test-1.template-test-1-canary.svc.cluster.local:8080/ || true
                sleep 0.5
              done
EOF

echo "==> [2/3] Setting FAULT_ERROR_RATE=${rate} across all three dev overlays"
set_fault_rate "${app_repo}/deploy/overlays/dev-rolling/patch-environment.yaml"
set_fault_rate "${app_repo}/deploy/overlays/dev-bluegreen/rollout.yaml"
set_fault_rate "${app_repo}/deploy/overlays/dev-canary/rollout.yaml"

if git -C "$app_repo" diff --quiet; then
  echo "    No change -- already at rate ${rate}."
else
  git -C "$app_repo" add \
    deploy/overlays/dev-rolling/patch-environment.yaml \
    deploy/overlays/dev-bluegreen/rollout.yaml \
    deploy/overlays/dev-canary/rollout.yaml
  git -C "$app_repo" commit -q -m "test: set FAULT_ERROR_RATE=${rate} across dev deployment-strategy variants"
  git -C "$app_repo" push origin main
fi

echo "==> [3/3] Done. Watch it happen:"
cat <<EOF

  Grafana (Progressive Delivery dashboard):
    kubectl --kubeconfig ${kubeconfig} -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 &
    open http://localhost:3000

  Rolling (no protection -- error rate should jump immediately, stays up until manually rolled back):
    kubectl --kubeconfig ${kubeconfig} -n template-test-1-rolling argo rollouts get rollout template-test-1 2>/dev/null || \\
      kubectl --kubeconfig ${kubeconfig} -n template-test-1-rolling rollout status deployment/template-test-1

  Blue-green (new ReplicaSet sits in preview -- inspect it, decide whether to promote):
    kubectl --kubeconfig ${kubeconfig} -n template-test-1-bluegreen argo rollouts get rollout template-test-1 --watch

  Canary (automated analysis should catch it and abort/rollback on its own):
    kubectl --kubeconfig ${kubeconfig} -n template-test-1-canary argo rollouts get rollout template-test-1 --watch

  Revert when done:
    ${repo_root}/scripts/simulate-bad-rollout.sh revert
EOF
