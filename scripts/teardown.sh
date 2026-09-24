#!/usr/bin/env bash
# Destroys an environment and removes its context from ~/.kube/config
# (bootstrap.sh's merge step, undone) so stale contexts for a cluster that
# no longer exists don't accumulate. `terraform destroy -auto-approve` --
# no interactive confirmation -- since invoking this script at all (or
# `make down`/scripts/down.sh, which calls it for all three environments)
# is already the explicit destructive action; a second prompt inside it
# would just be automation friction, not a real safety gate.
#
# Usage: scripts/teardown.sh [dev|prod]   (default: dev)
set -euo pipefail

env_name="${1:-dev}"
case "$env_name" in
  dev | prod) ;;
  *)
    echo "error: unknown environment '${env_name}' (expected dev or prod)" >&2
    exit 1
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_dir="${repo_root}/terraform/environments/${env_name}"

# shellcheck disable=SC1091
if [ -f "${repo_root}/.env.local" ]; then
  set -a
  source "${repo_root}/.env.local"
  set +a
fi

cluster_name="$(terraform -chdir="${env_dir}" output -raw cluster_name 2>/dev/null || echo "local-platform-${env_name}")"
context_name="kind-${cluster_name}"

# Lots of resources in this cluster carry finalizers that can only be
# cleared by their own owning controller: Argo CD's root/root-platform
# Applications (resources-finalizer.argocd.argoproj.io -- see
# platform/argocd/root-app*.yaml), and, on dev, ARC's AutoscalingRunnerSet/
# AutoscalingListener/EphemeralRunnerSet CRs (actions.github.com/*
# finalizers). Each of those controllers is itself being deleted as part of
# the same `terraform destroy` (its namespace and everything in it go
# together), so the finalizer can never actually get cleared -- deadlock.
# Confirmed live tearing down both prod (Argo CD) and dev (ARC) this way
# (Milestone 5, Phase 4). Since the whole cluster is coming down regardless
# -- `kind delete cluster` moments later -- there's nothing left to cascade
# to.
#
# Clearing finalizers alone isn't enough (also confirmed live), for two
# separate reasons:
#   - If the owning controller is still running, its normal reconcile loop
#     just re-adds its own finalizer to the object -- a race the
#     clear-then-destroy ordering loses. Argo CD's application-controller
#     is killed first, specifically, before touching anything else: it's
#     the one component whose reconcile loop (selfHeal) would otherwise
#     recreate whatever else this step deletes out from under it.
#   - Clearing cascades in waves, not one shot: a child resource's
#     finalizer sometimes only becomes clearable after ITS parent has
#     actually been garbage-collected (observed live: an
#     EphemeralRunnerSet's ServiceAccount/Role/RoleBinding only exposed
#     their own finalizer once the EphemeralRunnerSet itself was gone).
#     The sweep below repeats until a full pass finds nothing left to
#     clear, not just once.
kubeconfig_path="$(terraform -chdir="${env_dir}" output -raw kubeconfig_path 2>/dev/null || true)"
if [ -n "$kubeconfig_path" ] && [ -f "$kubeconfig_path" ]; then
  echo "==> Killing everything in argocd first so selfHeal can't recreate what this script deletes next"
  KUBECONFIG="$kubeconfig_path" kubectl -n argocd delete deployments,statefulsets,daemonsets --all --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  KUBECONFIG="$kubeconfig_path" kubectl -n argocd delete pods --all --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

  echo "==> Deleting all remaining workload controllers (except kube-system) so none can re-add a finalizer we're about to clear"
  app_namespaces="$(KUBECONFIG="$kubeconfig_path" kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -vE '^(kube-system|kube-node-lease|kube-public|local-path-storage|default)$' || true)"
  for ns in $app_namespaces; do
    KUBECONFIG="$kubeconfig_path" kubectl -n "$ns" delete deployments,statefulsets,daemonsets --all --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  done
  for ns in $app_namespaces; do
    KUBECONFIG="$kubeconfig_path" kubectl -n "$ns" delete pods --all --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
  done

  echo "==> Clearing finalizers cluster-wide (repeats until a full pass finds nothing left)"
  resource_types="$(KUBECONFIG="$kubeconfig_path" kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null || true)"
  for _ in $(seq 1 10); do
    cleared_any=false
    for resource in $resource_types; do
      names="$(KUBECONFIG="$kubeconfig_path" kubectl get "$resource" -A -o jsonpath='{range .items[?(@.metadata.finalizers)]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
      [ -z "$names" ] && continue
      while read -r ns name; do
        [ -z "$name" ] && continue
        KUBECONFIG="$kubeconfig_path" kubectl -n "$ns" patch "$resource" "$name" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 && cleared_any=true
      done <<<"$names"
    done
    if [ "$cleared_any" = false ]; then
      break
    fi
    sleep 3
  done
fi

terraform -chdir="${env_dir}" destroy -auto-approve

echo "==> Removing ${context_name} from ~/.kube/config"
kubectl config delete-context "${context_name}" >/dev/null 2>&1 || true
kubectl config delete-cluster "${context_name}" >/dev/null 2>&1 || true
kubectl config delete-user "${context_name}" >/dev/null 2>&1 || true

echo "==> Teardown complete (${env_name})."
