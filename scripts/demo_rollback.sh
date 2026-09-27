#!/usr/bin/env bash
# Local, non-production rollback demonstration for CCVIE.
#
# Demonstrates: start v1 -> deploy v2 -> health check -> simulated broken v2
# -> rollback to v1 -> health check passes. Docker only, no cloud, no
# Kubernetes, no canary/production infrastructure.
#
# ponytail: stands in with a throwaway busybox container until the real
# backend image exists (Phase 1). Once backend/Dockerfile is buildable,
# point CONTAINER_IMAGE / the deploy() calls at it and swap the health
# check path for the real API's health endpoint.
set -euo pipefail

CONTAINER=ccvie-rollback-demo
PORT="${DEMO_ROLLBACK_PORT:-8099}"
V1_DIR="$(mktemp -d)"
V2_DIR="$(mktemp -d)"
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$V1_DIR" "$V2_DIR"' EXIT

echo "ok-v1" > "$V1_DIR/health"
echo "broken-v2" > "$V2_DIR/health"   # simulated failed release: never reports "ok-v1"

health_check() {
  local expect="$1" tries=10
  for ((i = 1; i <= tries; i++)); do
    if curl -sf "http://localhost:${PORT}/health" 2>/dev/null | grep -q "$expect"; then
      echo "health check passed (expected: $expect)"
      return 0
    fi
    sleep 1
  done
  echo "health check FAILED (expected: $expect)" >&2
  return 1
}

deploy() {
  local dir="$1"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" -p "${PORT}:80" -v "${dir}:/www:ro" busybox httpd -f -p 80 -h /www >/dev/null
}

echo "== Start v1 =="
deploy "$V1_DIR"
health_check "ok-v1"

echo "== Deploy v2 (simulated broken release) =="
deploy "$V2_DIR"
if health_check "ok-v1"; then
  echo "v2 unexpectedly healthy; nothing to roll back."
  exit 0
fi

echo "== v2 failed its health check: rolling back to v1 =="
deploy "$V1_DIR"
health_check "ok-v1"
echo "== Rollback verified: v1 healthy again =="
