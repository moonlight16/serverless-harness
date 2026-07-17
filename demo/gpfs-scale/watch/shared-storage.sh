#!/usr/bin/env bash
# demo/gpfs-scale/watch/shared-storage.sh
# Live view of the shared-RWX PVC content across all 3 sandbox pods — the
# visual proof that they're mounting ONE filesystem, not 3 copies, plus a
# running view of the contention point (converge lock + repo dir) during an
# Act 2 run. Only meaningful under the Phase 2+ shared-RWX pool config
# (deploy/knative/agentic-cloud/sandbox-pool.yaml on
# experiment/shared-rwx-sandbox) — under the Phase 1 per-sandbox RWO config
# each pod will show a DIFFERENT /workspace, which is itself an instructive
# side-by-side if you run this before/after switching pool configs.
set -euo pipefail
NS="${NS:-serverless-harness}"
INTERVAL="${INTERVAL:-2}"

while true; do
  clear
  echo "=== shared /workspace — $(date '+%H:%M:%S') ==="
  echo
  for p in sandbox-0 sandbox-1 sandbox-2; do
    echo "--- $p:/workspace ---"
    kubectl --context agentic-cloud -n "$NS" exec "$p" -c sandbox -- \
      sh -c 'ls -la /workspace 2>/dev/null; echo; [ -f /workspace/.sh-fetch.lock ] && (echo "lock file present:"; ls -la /workspace/.sh-fetch.lock)' \
      2>/dev/null || echo "  (exec failed — pod not ready?)"
    echo
  done
  echo "--- fetch-lock holder (best-effort, via lsof if available) ---"
  kubectl --context agentic-cloud -n "$NS" exec sandbox-0 -c sandbox -- \
    sh -c 'command -v lsof >/dev/null && lsof /workspace/.sh-fetch.lock 2>/dev/null || echo "  (lsof unavailable in sandbox image)"' \
    2>/dev/null
  echo
  echo "--- leaves currently checked out (per-leaf worktrees, should be isolated even on shared FS) ---"
  kubectl --context agentic-cloud -n "$NS" exec sandbox-0 -c sandbox -- \
    sh -c 'ls -la /workspace/leaves 2>/dev/null || echo "  (no /workspace/leaves — none active or pre-P2 layout)"' \
    2>/dev/null
  sleep "$INTERVAL"
done
