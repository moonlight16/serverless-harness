#!/usr/bin/env bash
# demo/gpfs-scale/watch/harness-pods.sh
# Live view of the harness ksvc + leaf-worker scale-out (KEDA-driven during
# Act 2 async runs) — shows the 0 -> N -> Completed pattern.
set -euo pipefail
NS="${NS:-serverless-harness}"
INTERVAL="${INTERVAL:-2}"

while true; do
  clear
  echo "=== harness + leaf-workers — $(date '+%H:%M:%S') ==="
  echo
  echo "--- ksvc ---"
  kubectl --context agentic-cloud -n "$NS" get ksvc serverless-harness
  echo
  echo "--- harness / gitd / redis pods ---"
  kubectl --context agentic-cloud -n "$NS" get pods 2>/dev/null | grep -E 'serverless-harness-[0-9a-z]+-deployment|redis|gitd' || echo "  (none running — scaled to zero, normal when idle)"
  echo
  echo "--- leaf-worker pods (KEDA ScaledJob) ---"
  kubectl --context agentic-cloud -n "$NS" get pods -l app=leaf-worker 2>/dev/null || echo "  (none)"
  echo
  echo "--- leaf-queue depth / consumer group lag ---"
  kubectl --context agentic-cloud -n "$NS" exec deploy/redis -- redis-cli XINFO GROUPS leaf-queue 2>/dev/null \
    | paste - - | column -t || echo "  (leaf-queue stream not present)"
  sleep "$INTERVAL"
done
