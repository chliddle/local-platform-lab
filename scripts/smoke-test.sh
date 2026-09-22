#!/usr/bin/env bash
# Asserts the platform's app contract (CLAUDE.md's Example Applications
# section): every app exposes /, /health, /ready, /version, /metrics.
set -euo pipefail

base_url="$1"

check() {
  local path="$1" expect_status="$2"
  status=$(curl -s -o /dev/null -w "%{http_code}" "${base_url}${path}")
  if [ "$status" != "$expect_status" ]; then
    echo "FAIL: $path expected $expect_status, got $status"
    exit 1
  fi
  echo "OK: $path -> $status"
}

check "/" 200
check "/health" 200
check "/ready" 200
check "/version" 200
check "/metrics" 200

version_json=$(curl -s "${base_url}/version")
echo "version response: $version_json"
echo "$version_json" | grep -q '"name"' || {
  echo "FAIL: /version missing expected 'name' field"
  exit 1
}

echo "smoke test passed"
