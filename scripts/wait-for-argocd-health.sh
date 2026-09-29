#!/usr/bin/env bash
# Extracted from promote-platform.yml's own inline poll loop (this is the
# same logic, unchanged, just shared) so check-app-dev-health.yml can reuse
# it for app-level dev-health gating instead of duplicating it.
#
# Takes an explicit list of Application names (callers decide whether that's
# "everything in the namespace", dynamically discovered, or a fixed subset --
# see promote-platform.yml vs check-app-dev-health.yml for the two different
# choices this project makes).
#
# Treats Synced+Healthy AND Synced+Suspended as passing, not Healthy alone:
# confirmed live that template-test-1-bluegreen's Application reports
# health.status=Suspended (not Healthy) while its Rollout sits paused
# awaiting manual promotion -- which, per Milestone 6's design, is
# blue-green's normal, permanent steady state until someone runs
# `kubectl argo rollouts promote` by hand. Argo CD's own Rollout health
# check maps a paused blue-green phase to Suspended deliberately (it's not
# a generic "something's wrong" status) -- treating it as a pass preserves
# promote-platform.yml's original intent ("did this infra change break
# dev", checking every onboarded app, not just platform components)
# without being permanently blocked by blue-green's by-design manual gate.
# A real bug existed here before this extraction: the original inline
# version required Healthy strictly, so it was live-blocked any time
# blue-green sat paused -- which is most of the time.
#
# Must run on a pod with an in-cluster ServiceAccount token scoped to
# get/list/watch Applications in the given namespace (see
# terraform/environments/dev/main.tf's runner_reads_dev_argocd binding) --
# this is meant to run on platform-runners, not a GitHub-hosted runner,
# since only the in-cluster pod has network reach to the real kube-apiserver.
#
# Usage: scripts/wait-for-argocd-health.sh <namespace> <app-name> [app-name...]
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <namespace> <app-name> [app-name...]" >&2
  exit 2
fi

namespace="$1"
shift
app_names="$*"

sa_token_path=/var/run/secrets/kubernetes.io/serviceaccount/token
sa_ca_path=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

deadline=$((SECONDS + 300))
while true; do
  not_ready=""
  for name in $app_names; do
    sync_status=$(kubectl --server=https://kubernetes.default.svc --token="$(cat "$sa_token_path")" --certificate-authority="$sa_ca_path" \
      -n "$namespace" get application "$name" -o jsonpath='{.status.sync.status}')
    health_status=$(kubectl --server=https://kubernetes.default.svc --token="$(cat "$sa_token_path")" --certificate-authority="$sa_ca_path" \
      -n "$namespace" get application "$name" -o jsonpath='{.status.health.status}')
    if [ "$sync_status" != "Synced" ] || { [ "$health_status" != "Healthy" ] && [ "$health_status" != "Suspended" ]; }; then
      not_ready="${not_ready}${name}: sync=${sync_status} health=${health_status}"$'\n'
    fi
  done
  if [ -z "$not_ready" ]; then
    echo "All of [$app_names] Synced+Healthy(or Suspended)."
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::Timed out waiting for [$app_names] to become healthy. Not Synced+Healthy:"
    echo "$not_ready"
    exit 1
  fi
  echo "Not yet healthy, retrying in 15s:"
  echo "$not_ready"
  sleep 15
done
