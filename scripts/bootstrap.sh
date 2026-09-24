#!/usr/bin/env bash
# Recreates a whole environment. Both dev and prod get a Kind cluster +
# Argo CD + a root Application (gitops/<env>/apps -- onboarded self-service
# apps) + a root-platform Application (platform/gitops-platform-apps,
# shared across both clusters, plus gitops/<env>/platform for what
# genuinely can't be shared -- see root-platform-dev.yaml's comment). dev
# additionally hosts the platform's own tooling (ARC, rootless BuildKit --
# see CLAUDE.md's GitHub Actions Runners section for why there's no
# separate management cluster for this). Everything past Argo CD itself is
# GitOps-managed, not applied directly by this script or Terraform -- it
# becomes ready asynchronously as Argo CD reconciles, same as
# template-test-1. Idempotent -- safe to re-run.
#
# Usage: scripts/bootstrap.sh [dev|prod]   (default: dev)
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

echo "==> Checking prerequisites (${env_name})"

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker daemon is not running. Start Docker Desktop and re-run." >&2
  exit 1
fi

for cmd in kind kubectl helm terraform; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command '$cmd' not found on PATH." >&2
    exit 1
  fi
done

# github_username/github_token are needed by both environments -- each
# cluster's own Argo CD reads this private repo via the same repo-creds
# credential template, and both use it for a GHCR imagePullSecret. dev
# additionally needs the ARC runner PAT below.
if [ -z "${TF_VAR_github_username:-}" ] || [ -z "${TF_VAR_github_token:-}" ]; then
  cat >&2 <<'EOF'
error: TF_VAR_github_username and TF_VAR_github_token must be set.

This seeds each cluster's Argo CD repo-credentials secret, so it can read
this private repo, and its GHCR imagePullSecret, so the Kind node can pull
the private template-test-1 image.

Create a classic GitHub PAT (not fine-grained -- fine-grained PATs have no
"Packages" permission at all, so GHCR auth requires classic) with scopes
repo + read:packages, then either:

  cp .env.local.example .env.local   # fill in the values, bootstrap.sh sources it

or:

  export TF_VAR_github_username=<your-github-username>
  export TF_VAR_github_token=<the-pat>
EOF
  exit 1
fi

if [ "$env_name" = "dev" ] && [ -z "${TF_VAR_arc_runner_pat:-}" ]; then
  cat >&2 <<'EOF'
error: TF_VAR_arc_runner_pat must be set.

This registers a self-hosted GitHub Actions runner (via ARC) against
chliddle/local-platform-lab. Create a fine-grained PAT scoped only to that
one repository, permission Repository administration: Read and write,
then either:

  cp .env.local.example .env.local   # fill in the value, bootstrap.sh sources it

or:

  export TF_VAR_arc_runner_pat=<the PAT>
EOF
  exit 1
fi

echo "==> Applying Terraform"
terraform -chdir="${env_dir}" init -upgrade
terraform -chdir="${env_dir}" apply -auto-approve

kubeconfig_path="$(terraform -chdir="${env_dir}" output -raw kubeconfig_path)"
cluster_name="$(terraform -chdir="${env_dir}" output -raw cluster_name)"

argocd_namespace="$(terraform -chdir="${env_dir}" output -raw argocd_namespace)"
echo "==> Waiting for Argo CD server to be ready"
KUBECONFIG="${kubeconfig_path}" kubectl -n "${argocd_namespace}" rollout status deployment/argocd-server --timeout=180s

# kube-prometheus-stack (both environments) and ARC (dev only) ship CRDs
# too large for Argo CD to sync safely -- see scripts/pre-apply-large-crds.sh
# for the two distinct ways that fails live. Has to happen before the
# health-wait below: those Applications can never reach Healthy without
# their CRDs existing first.
echo "==> Pre-applying large CRDs Argo CD can't sync safely"
"${repo_root}/scripts/pre-apply-large-crds.sh" "$env_name"

# blackbox-exporter needs a Secret (this cluster's own root CA, copied from
# cert-manager's namespace) and a Probe (this cluster's own Gateway IP)
# that only this script can see live -- same reasoning as every other
# script-bridged value in this project. Runs here, before the health-wait
# below, so blackbox-exporter's Secret already exists by the time Argo CD
# gets to it -- avoids the circular "Application can never go healthy
# without a Secret only a post-bootstrap script creates" trap a cross-
# cluster version of this hit in an earlier design (see git history).
echo "==> Syncing this cluster's monitoring targets (CA, blackbox probe)"
"${repo_root}/scripts/sync-monitoring-targets.sh" "$env_name"

# Waits for every Application (not just argocd-server) to be Synced+Healthy
# before this script -- and scripts/up.sh, which bootstraps one environment
# at a time -- moves on. Confirmed live (Milestone 5, Phase 4) this matters:
# bootstrapping multiple clusters concurrently let their reconcile storms
# (first-time chart pulls, CRD registration, webhook cert generation)
# overlap, which starved the shared Docker Desktop VM badly enough to make
# even the real Kubernetes control plane (kube-controller-manager,
# kube-scheduler) lose leader election. One environment fully settled
# before the next one starts is slower end to end but doesn't compound.
echo "==> Waiting for every Application to be Synced+Healthy (can take a while on a fresh bootstrap -- chart/image pulls for everything at once)"
deadline=$((SECONDS + 1800))
while true; do
  app_names="$(KUBECONFIG="${kubeconfig_path}" kubectl -n "${argocd_namespace}" get applications -o jsonpath='{.items[*].metadata.name}')"
  not_ready=""
  if [ -z "$app_names" ]; then
    not_ready="(no Applications registered yet)"
  else
    for name in $app_names; do
      sync_status="$(KUBECONFIG="${kubeconfig_path}" kubectl -n "${argocd_namespace}" get application "$name" -o jsonpath='{.status.sync.status}')"
      health_status="$(KUBECONFIG="${kubeconfig_path}" kubectl -n "${argocd_namespace}" get application "$name" -o jsonpath='{.status.health.status}')"
      if [ "$sync_status" != "Synced" ] || [ "$health_status" != "Healthy" ]; then
        not_ready="${not_ready}${name}: sync=${sync_status} health=${health_status}"$'\n'
      fi
    done
  fi
  if [ -z "$not_ready" ]; then
    echo "    All Applications Synced+Healthy."
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "error: timed out waiting for ${env_name}'s Applications to become healthy. Not Synced+Healthy:" >&2
    echo "$not_ready" >&2
    exit 1
  fi
  sleep 15
done

# Belt-and-suspenders on top of the Application-level check above: Argo
# CD's health assessment for Deployments/StatefulSets/DaemonSets already
# implies their pods are Ready in the common case, but doesn't cover
# everything (one-shot Jobs, resource kinds its health check doesn't model
# closely) -- and doesn't guarantee every pod is READY at the exact instant
# health flips to true. Confirmed live this matters: check this directly.
echo "==> Waiting for every pod cluster-wide to be Ready"
# Excludes Succeeded/Failed pods -- completed Helm hook Jobs (e.g.
# kube-prometheus-stack's admission-webhook cert generator) leave a pod
# behind in Succeeded phase that will never satisfy condition=Ready;
# without this filter the wait just burns its full timeout on those.
KUBECONFIG="${kubeconfig_path}" kubectl wait --for=condition=Ready pod --all --all-namespaces \
  --field-selector=status.phase!=Succeeded,status.phase!=Failed \
  --timeout=300s

# Real settle time before this script returns -- and before scripts/up.sh
# starts the next environment's bootstrap. Confirmed live (this session)
# that "Applications report Healthy" is not the same as "load has actually
# stopped": a shared disruption hit all three clusters' control planes
# minutes after they'd each reported healthy, consistent with residual
# reconcile/cache-warming work (or simply CPU easing back down) still in
# flight right after the health gate passes. Cheap insurance against
# starting the next cluster's own reconcile storm on top of that tail.
echo "==> Settling for 60s before considering ${env_name} done"
sleep 60

echo "==> Merging context into ~/.kube/config"
context_name="kind-${cluster_name}"
mkdir -p "${HOME}/.kube"

# Serialize this against any other bootstrap.sh run merging into the same
# ~/.kube/config at the same time (e.g. `make up` bootstrapping one
# environment while a manual `make bootstrap-prod` runs in another
# terminal). `kubectl config view --flatten` reads then rewrites the whole
# file non-atomically -- confirmed live this session that two overlapping
# runs can race and one write's result silently clobbers the other's,
# up to and including reducing ~/.kube/config to empty. mkdir is an atomic,
# dependency-free lock primitive (flock isn't installed on macOS by
# default, confirmed on this machine).
lock_dir="${HOME}/.kube/.local-platform-lab.lock"
lock_attempts=0
while ! mkdir "$lock_dir" 2>/dev/null; do
  lock_attempts=$((lock_attempts + 1))
  if [ "$lock_attempts" -ge 60 ]; then
    echo "error: timed out waiting for the ~/.kube/config lock (${lock_dir}) -- held by another bootstrap.sh run? remove it manually if that run crashed." >&2
    exit 1
  fi
  sleep 1
done
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

[ -f "${HOME}/.kube/config" ] && cp "${HOME}/.kube/config" "${HOME}/.kube/config.bak"
merged="$(KUBECONFIG="${HOME}/.kube/config:${kubeconfig_path}" kubectl config view --flatten)"
# Sanity check before overwriting: the merge result must actually contain
# the context this run just bootstrapped. A merge that's missing it (or
# came back empty) means something upstream went wrong -- e.g. a stale/
# empty KUBECONFIG mid-race -- and writing it would silently wipe every
# other context already in this file, contexts for other clusters/
# projects included.
if ! grep -q "name: ${context_name}$" <<<"$merged"; then
  echo "warning: merged kubeconfig doesn't contain ${context_name} -- not touching ~/.kube/config to avoid wiping it. ${kubeconfig_path} still works standalone; re-run this script if the merge should have worked." >&2
else
  printf '%s\n' "$merged" >"${HOME}/.kube/config.new"
  mv "${HOME}/.kube/config.new" "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config"
fi

rmdir "$lock_dir" 2>/dev/null || true
trap - EXIT

cat <<EOF

==> Bootstrap complete (${env_name}).

Use this cluster (merged into ~/.kube/config -- the isolated
${kubeconfig_path} still works too, e.g. for scripting):
  kubectl config use-context ${context_name}

Argo CD UI (admin password below, then browse https://localhost:8080):
  kubectl -n ${argocd_namespace} port-forward svc/argocd-server 8080:443 &
  kubectl -n ${argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
EOF

cat <<EOF
Check the template-test-1 app synced:
  kubectl -n ${argocd_namespace} get application template-test-1 -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
EOF

if [ "$env_name" = "dev" ]; then
  cat <<EOF

Check arc-controller/arc-runners/buildkit synced (may take a minute after
a fresh apply -- Argo CD reconciles these, this script doesn't wait on it):
  kubectl -n ${argocd_namespace} get applications arc-controller arc-runners buildkit

Check the runner scale set registered with GitHub:
  kubectl -n arc-systems logs -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50

List runner pods (only appear once a workflow run is queued -- minRunners is 0):
  kubectl -n arc-runners get pods
EOF
fi
