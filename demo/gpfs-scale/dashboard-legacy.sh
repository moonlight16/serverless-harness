#!/usr/bin/env bash
# Original shell dashboard retained as a lightweight fallback/reference.
# Environment: RUN_PID RUN_LOG ACT MODEL KUBE_CONTEXT KAGENTI_NS KAGENTI_KSVC
#              KAGENTI_POOL_SELECTOR; optional INTERVAL (default 5).
set -euo pipefail

: "${RUN_PID:?}"
: "${RUN_LOG:?}"
: "${ACT:?}"
: "${MODEL:?}"
: "${KUBE_CONTEXT:?}"
: "${KAGENTI_NS:?}"
: "${KAGENTI_KSVC:?}"
: "${KAGENTI_POOL_SELECTOR:?}"
INTERVAL="${INTERVAL:-5}"
STARTED="$(date +%s)"

while kill -0 "$RUN_PID" 2>/dev/null; do
  FRAME="$(mktemp)"
  {
    elapsed=$(($(date +%s) - STARTED))
    printf 'BUGSTONE + SHARED GPFS  |  %s  |  %ss  |  %s\n' "$ACT" "$elapsed" "$MODEL"
    echo
    echo '=== SANDBOX POOL / SHARED CLAIM ==='
    kubectl --context "$KUBE_CONTEXT" -n "$KAGENTI_NS" get pods \
      -l "$KAGENTI_POOL_SELECTOR" \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName' 2>/dev/null || true
    echo
    echo '=== KNATIVE HARNESS PODS ==='
    kubectl --context "$KUBE_CONTEXT" -n "$KAGENTI_NS" get pods \
      -l serving.knative.dev/service="$KAGENTI_KSVC" \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName' \
      2>/dev/null || true
    echo
    echo '=== KEDA LEAF WORKERS ==='
    kubectl --context "$KUBE_CONTEXT" -n "$KAGENTI_NS" get pods -l app=leaf-worker \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName' \
      2>/dev/null || true
    printf 'queue depth: '
    kubectl --context "$KUBE_CONTEXT" -n "$KAGENTI_NS" exec deploy/redis -- \
      redis-cli XLEN leaf-queue 2>/dev/null || echo unavailable
    echo
    echo '=== SHARED /workspace ==='
    # shellcheck disable=SC2016
    kubectl --context "$KUBE_CONTEXT" -n "$KAGENTI_NS" exec sandbox-0 -c sandbox -- sh -c '
      repo=no; [ -d /workspace/repo ] && repo=yes
      leaves=0; [ -d /workspace/leaves ] && leaves=$(find /workspace/leaves -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d " ")
      printf "repository=%s  active-worktrees=%s\n/workspace/\n" "$repo" "$leaves"
      ls -A /workspace 2>/dev/null | sort | sed "s/^/  |-- /"
    ' 2>/dev/null || true
    echo
    echo '=== BUGSTONE MILESTONES ==='
    grep -E '^\[(poc|async|stage)\]|passed=|done\.|ERROR|error:|failed' "$RUN_LOG" \
      2>/dev/null | tail -n 8 || true
    echo
    echo '=== LIVE LOG ==='
    tail -n 12 "$RUN_LOG" 2>/dev/null || true
  } >"$FRAME"
  printf '\033[2J\033[H'
  command cat "$FRAME"
  rm -f "$FRAME"
  sleep "$INTERVAL"
done
