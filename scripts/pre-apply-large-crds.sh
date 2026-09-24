#!/usr/bin/env bash
# Pre-applies CustomResourceDefinitions that are too large for Argo CD to
# sync safely -- confirmed live on a from-scratch bootstrap, two distinct
# failure modes:
#
#   - ARC's CRDs (up to ~1.2MB each): client-side apply's
#     kubectl.kubernetes.io/last-applied-configuration annotation exceeds
#     Kubernetes' 262144-byte annotation limit outright (a hard apply
#     failure -- see gitops/dev/platform/arc-controller.yaml's syncOptions
#     comment).
#   - kube-prometheus-stack's CRDs (up to ~850KB each) and Argo Rollouts'
#     CRDs (up to ~240KB each, confirmed live via `helm pull` + measuring
#     the rendered YAML -- comparable, not "much smaller" as first
#     assumed): even with ServerSideApply/Replace avoiding the annotation
#     problem, Argo CD's application-controller writing its own
#     operation/sync-result status back onto the Application object hit
#     etcd's request-size limit ("etcdserver: request is too large") for
#     kube-prometheus-stack -- not an apply failure, but a permanently
#     stuck sync operation, arguably worse since it's silent until you go
#     looking. Applied Argo Rollouts' CRDs the same way pre-emptively
#     rather than risk hitting the same failure live.
#
# All three are structural size problems, not something resource limits or
# syncOptions alone fix -- so all three charts' CRDs get applied here
# directly, with real cluster access (server-side apply, no size-limited
# annotation), before Argo CD ever attempts them itself. Once they already
# match, Argo CD's sync for ARC/Argo Rollouts either sees nothing to do or
# a small enough diff to stay under the size limits; kube-prometheus-stack
# never tries at all (crds.enabled: false on that Application).
#
# ARC and kube-prometheus-stack are dev only: both live on dev, not prod
# -- confirmed live that duplicating the observability stack onto prod
# doesn't fit in this VM's 7.65GiB alongside everything else both clusters
# already run (see gitops/dev/platform/kube-prometheus-stack.yaml's
# comment). Argo Rollouts runs on BOTH dev and prod (Milestone 6 -- the
# dev->prod promotion pattern needs the same Rollout CRDs/controller on
# both), so its CRD step below is NOT gated behind the dev-only check.
#
# Idempotent (server-side apply) -- safe to re-run.
#
# Usage: scripts/pre-apply-large-crds.sh <dev|prod>
set -euo pipefail

env_name="${1:?usage: pre-apply-large-crds.sh <dev|prod>}"
case "$env_name" in
  dev | prod) ;;
  *)
    echo "error: unknown environment '${env_name}' (expected dev or prod)" >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubeconfig="${repo_root}/terraform/environments/${env_name}/kubeconfig-local-platform-${env_name}"

if [ ! -f "$kubeconfig" ]; then
  echo "error: ${env_name} kubeconfig not found at ${kubeconfig}." >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "==> Rendering argo-rollouts chart 2.43.2's CRDs"
# Unlike ARC's/kube-prometheus-stack's CRDs (plain static YAML under each
# chart's special crds/ directory, safe to kubectl apply directly), Argo
# Rollouts puts its CRDs under templates/crds/ -- real Helm templates
# (each gated by `{{- if .Values.installCRDs }}`), confirmed live: a raw
# `kubectl apply -f` on the untarred file fails with a Go-template-syntax
# JSON parse error. `helm template` renders them properly; --show-only
# limits the render to just the CRD templates, not the whole chart
# (RBAC/Deployment/etc. stay Argo CD's job).
helm template argo-rollouts --repo https://argoproj.github.io/argo-helm \
  --version 2.43.2 --set installCRDs=true \
  --show-only templates/crds/analysis-run-crd.yaml \
  --show-only templates/crds/analysis-template-crd.yaml \
  --show-only templates/crds/cluster-analysis-template-crd.yaml \
  --show-only templates/crds/experiment-crd.yaml \
  --show-only templates/crds/rollout-crd.yaml \
  >"${work_dir}/rollouts-crds.yaml"

echo "==> Server-side applying Argo Rollouts' CRDs"
KUBECONFIG="$kubeconfig" kubectl apply --server-side -f "${work_dir}/rollouts-crds.yaml"

if [ "$env_name" != "dev" ]; then
  echo "==> ${env_name} runs neither ARC nor the observability stack -- nothing further to pre-apply."
  exit 0
fi

echo "==> Pulling kube-prometheus-stack chart 91.5.0 for its CRDs"
helm pull kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
  --version 91.5.0 --untar -d "${work_dir}/kps" >/dev/null

echo "==> Server-side applying kube-prometheus-stack's CRDs"
for f in "${work_dir}"/kps/kube-prometheus-stack/charts/crds/crds/*.yaml; do
  KUBECONFIG="$kubeconfig" kubectl apply --server-side -f "$f"
done

echo "==> Pulling ARC controller chart 0.14.2 for its CRDs"
helm pull oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version 0.14.2 --untar -d "${work_dir}/arc" >/dev/null

echo "==> Server-side applying ARC's CRDs"
for f in "${work_dir}"/arc/gha-runner-scale-set-controller/crds/*.yaml; do
  KUBECONFIG="$kubeconfig" kubectl apply --server-side -f "$f"
done

echo "==> Done."
