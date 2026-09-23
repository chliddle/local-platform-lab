#!/usr/bin/env bash
# Milestone 5, Phase 4: pre-applies CustomResourceDefinitions that are too
# large for Argo CD to sync safely -- confirmed live on management's
# from-scratch bootstrap, two distinct failure modes:
#
#   - ARC's CRDs (up to ~1.2MB each): client-side apply's
#     kubectl.kubernetes.io/last-applied-configuration annotation exceeds
#     Kubernetes' 262144-byte annotation limit outright (a hard apply
#     failure -- see gitops/management/platform/arc-controller.yaml's
#     syncOptions comment).
#   - kube-prometheus-stack's CRDs (up to ~850KB each): even with
#     ServerSideApply/Replace avoiding the annotation problem, Argo CD's
#     application-controller writing its own operation/sync-result status
#     back onto the Application object hit etcd's request-size limit
#     ("etcdserver: request is too large") -- not an apply failure, but a
#     permanently stuck sync operation, arguably worse since it's silent
#     until you go looking. Fixed by excluding these CRDs from that
#     Application's own management entirely (crds.enabled: false).
#
# Both are structural size problems, not something resource limits or
# syncOptions alone fix -- so both charts' CRDs get applied here directly,
# with real cluster access (server-side apply, no size-limited annotation),
# before Argo CD ever attempts them itself. Once they already match, Argo
# CD's sync for ARC either sees nothing to do or a small enough diff to
# stay under the size limits; kube-prometheus-stack never tries at all.
#
# Idempotent (server-side apply) -- safe to re-run. Management only: dev
# and prod don't run either of these charts.
#
# Usage: scripts/pre-apply-large-crds.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mgmt_kubeconfig="${repo_root}/terraform/environments/management/kubeconfig-local-platform-management"

if [ ! -f "$mgmt_kubeconfig" ]; then
  echo "error: management cluster kubeconfig not found at ${mgmt_kubeconfig}." >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "==> Pulling ARC controller chart 0.14.2 for its CRDs"
helm pull oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version 0.14.2 --untar -d "${work_dir}/arc" >/dev/null

echo "==> Pulling kube-prometheus-stack chart 91.5.0 for its CRDs"
helm pull kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
  --version 91.5.0 --untar -d "${work_dir}/kps" >/dev/null

echo "==> Server-side applying ARC's CRDs"
for f in "${work_dir}"/arc/gha-runner-scale-set-controller/crds/*.yaml; do
  KUBECONFIG="$mgmt_kubeconfig" kubectl apply --server-side -f "$f"
done

echo "==> Server-side applying kube-prometheus-stack's CRDs"
for f in "${work_dir}"/kps/kube-prometheus-stack/charts/crds/crds/*.yaml; do
  KUBECONFIG="$mgmt_kubeconfig" kubectl apply --server-side -f "$f"
done

echo "==> Done."
