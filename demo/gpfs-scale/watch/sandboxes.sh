#!/usr/bin/env bash
# demo/gpfs-scale/watch/sandboxes.sh
# Live view of the sandbox pool: pod status, node placement (spread proof),
# and which PVC(s) they're mounting (per-sandbox RWO vs. shared RWX).
set -euo pipefail
NS="${NS:-serverless-harness}"
INTERVAL="${INTERVAL:-2}"

while true; do
  clear
  echo "=== sandbox pool — $(date '+%H:%M:%S') ==="
  echo
  kubectl --context agentic-cloud -n "$NS" get pods -l sh.kagenti.io/sandbox-pool=default -o wide 2>/dev/null \
    || kubectl --context agentic-cloud -n "$NS" get pods -l app=sandbox -o wide
  echo
  echo "--- PVC claim per pod (workspace volume) ---"
  for p in sandbox-0 sandbox-1 sandbox-2; do
    claim=$(kubectl --context agentic-cloud -n "$NS" get pod "$p" \
      -o jsonpath='{.spec.volumes[?(@.name=="workspace")].persistentVolumeClaim.claimName}' 2>/dev/null)
    echo "  $p -> ${claim:-<not found>}"
  done
  echo
  echo "--- PVCs in namespace ---"
  kubectl --context agentic-cloud -n "$NS" get pvc
  sleep "$INTERVAL"
done
