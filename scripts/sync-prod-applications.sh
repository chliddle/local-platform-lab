#!/usr/bin/env bash
# promote-platform.yml's actual promotion action, since the platform repo
# moved off a separate prod branch (see platform/argocd/bootstrap-chart/
# templates/root-platform-app.yaml's comment): every prod platform
# Application now tracks main directly but with no syncPolicy.automated,
# so it sits OutOfSync until explicitly told to sync. This triggers that
# sync via `kubectl patch application ... operation.sync` -- the same
# mechanism Argo CD's own `argocd app sync` CLI uses under the hood, no
# separate Argo CD API/CLI credential needed, reusing the same
# prod-argocd-reader token this project already extracts cross-cluster
# (scripts/sync-runner-creds.sh) for read-only health checks, now also
# granted `patch` on a fixed, named set of Applications (platform/rbac/
# prod-ci-argocd-reader/rbac.yaml).
#
# Takes an explicit list of Application names, not "discover every
# OutOfSync Application" -- deliberately: the RBAC grant above is itself a
# fixed, named resourceNames list (K8s RBAC can't wildcard it), so
# attempting to patch some other, unrelated OutOfSync Application (e.g.
# template-test-1, which syncs on its own automated policy and could be
# transiently OutOfSync for an unrelated reason) would just fail on a 403
# and abort the whole promotion. Callers pass exactly the names RBAC
# already permits.
#
# root-platform first, deliberately, then the rest in the order given:
# it's the app-of-apps root -- syncing it creates/updates the child
# Application *objects* (matching whatever's on main now), but doesn't
# sync their payloads. A child can also be independently OutOfSync on its
# own (its target path changed, not just its own Application definition),
# so each of the rest gets its own discover-and-sync check after
# root-platform settles, not a blind sync.
#
# Usage: scripts/sync-prod-applications.sh <server> <token> <ca-file> <app-name> [app-name...]
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "Usage: $0 <server> <token> <ca-file> <app-name> [app-name...]" >&2
  exit 2
fi

server="$1"
token="$2"
ca_file="$3"
shift 3

kc() {
  kubectl --server="$server" --token="$token" --certificate-authority="$ca_file" "$@"
}

sync_and_wait() {
  local name="$1"
  echo "Syncing ${name}..."
  kc -n argocd patch application "$name" --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'

  local deadline=$((SECONDS + 300))
  while true; do
    local sync_status health_status
    sync_status=$(kc -n argocd get application "$name" -o jsonpath='{.status.sync.status}')
    health_status=$(kc -n argocd get application "$name" -o jsonpath='{.status.health.status}')
    if [ "$sync_status" = "Synced" ] && { [ "$health_status" = "Healthy" ] || [ "$health_status" = "Suspended" ]; }; then
      echo "${name}: Synced+${health_status}."
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "::error::Timed out waiting for ${name} to become Synced+Healthy (sync=${sync_status} health=${health_status})."
      return 1
    fi
    sleep 10
  done
}

for name in "$@"; do
  if [ "$name" = "root-platform" ]; then
    sync_and_wait root-platform
  fi
done

for name in "$@"; do
  if [ "$name" = "root-platform" ]; then
    continue
  fi
  sync_status=$(kc -n argocd get application "$name" -o jsonpath='{.status.sync.status}')
  if [ "$sync_status" != "Synced" ]; then
    sync_and_wait "$name"
  else
    echo "${name}: already Synced, skipping."
  fi
done

echo "All requested prod Applications Synced."
