#!/usr/bin/env bash
# Recreates a whole environment. All three environments get a Kind cluster
# + Argo CD + a root Application (dev/prod: gitops/<env>/apps -- onboarded
# self-service apps; management: gitops/management/platform -- ARC, rootless
# BuildKit, and this cluster's own platform tooling). Everything past Argo
# CD itself is GitOps-managed, not applied directly by this script or
# Terraform -- it becomes ready asynchronously as Argo CD reconciles, same
# as template-test-1 in dev/prod. Idempotent -- safe to re-run.
#
# Usage: scripts/bootstrap.sh [dev|prod|management]   (default: dev)
set -euo pipefail

env_name="${1:-dev}"
case "$env_name" in
  dev | prod | management) ;;
  *)
    echo "error: unknown environment '${env_name}' (expected dev, prod, or management)" >&2
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

# github_username/github_token are needed by all three environments now --
# each cluster's own Argo CD reads this private repo via the same
# repo-creds credential template. dev/prod additionally use it for a GHCR
# imagePullSecret; management additionally needs the ARC runner PAT below.
if [ -z "${TF_VAR_github_username:-}" ] || [ -z "${TF_VAR_github_token:-}" ]; then
  cat >&2 <<'EOF'
error: TF_VAR_github_username and TF_VAR_github_token must be set.

This seeds each cluster's Argo CD repo-credentials secret, so it can read
this private repo (dev/prod additionally use it for a GHCR imagePullSecret,
so the Kind node can pull the private template-test-1 image).

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

if [ "$env_name" = "management" ] && [ -z "${TF_VAR_arc_runner_pat:-}" ]; then
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

# Same wait for all three environments now -- everything past Argo CD
# itself (ARC, BuildKit, onboarded apps) is GitOps-managed and becomes
# ready asynchronously as Argo CD reconciles.
argocd_namespace="$(terraform -chdir="${env_dir}" output -raw argocd_namespace)"
echo "==> Waiting for Argo CD server to be ready"
KUBECONFIG="${kubeconfig_path}" kubectl -n "${argocd_namespace}" rollout status deployment/argocd-server --timeout=180s

# Waits for every Application (not just argocd-server) to be Synced+Healthy
# before this script -- and scripts/up.sh, which bootstraps one environment
# at a time -- moves on. Confirmed live (Milestone 5, Phase 4) this matters:
# bootstrapping dev/prod/management concurrently let their reconcile storms
# (first-time chart pulls, CRD registration, webhook cert generation)
# overlap, which starved the shared Docker Desktop VM badly enough to make
# even the real Kubernetes control plane (kube-controller-manager,
# kube-scheduler) lose leader election. One environment fully settled
# before the next one starts is slower end to end but doesn't compound.
echo "==> Waiting for every Application to be Synced+Healthy (can take several minutes on a fresh bootstrap -- chart/image pulls)"
deadline=$((SECONDS + 900))
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

echo "==> Merging context into ~/.kube/config"
mkdir -p "${HOME}/.kube"
[ -f "${HOME}/.kube/config" ] && cp "${HOME}/.kube/config" "${HOME}/.kube/config.bak"
KUBECONFIG="${HOME}/.kube/config:${kubeconfig_path}" kubectl config view --flatten >"${HOME}/.kube/config.new"
mv "${HOME}/.kube/config.new" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
context_name="kind-${cluster_name}"

cat <<EOF

==> Bootstrap complete (${env_name}).

Use this cluster (merged into ~/.kube/config -- the isolated
${kubeconfig_path} still works too, e.g. for scripting):
  kubectl config use-context ${context_name}

Argo CD UI (admin password below, then browse https://localhost:8080):
  kubectl -n ${argocd_namespace} port-forward svc/argocd-server 8080:443 &
  kubectl -n ${argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
EOF

if [ "$env_name" = "management" ]; then
  cat <<EOF
Check arc-controller/arc-runners/buildkit synced (may take a minute after
a fresh apply -- Argo CD reconciles these, this script doesn't wait on it):
  kubectl -n ${argocd_namespace} get applications arc-controller arc-runners buildkit

Check the runner scale set registered with GitHub:
  kubectl -n arc-systems logs -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50

List runner pods (only appear once a workflow run is queued -- minRunners is 0):
  kubectl -n arc-runners get pods
EOF
else
  cat <<EOF
Check the template-test-1 app synced:
  kubectl -n ${argocd_namespace} get application template-test-1 -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
EOF
fi
