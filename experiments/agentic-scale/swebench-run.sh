#!/usr/bin/env bash
# Run the proven SWE-bench path with Context Service-managed Sandbox/PVC allocation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KV="local"
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  echo "usage: $0 [--kv memory|local|scale]"
  echo "env: INSTANCE, AGENTS, SANDBOXES, WORKSPACE=scale|local, EVALUATE=0|1"
  exit 0
fi
if [ "${1:-}" = --kv ]; then KV="${2:?--kv requires memory, local, or scale}"; shift 2; fi
[ "$#" -eq 0 ] || { echo "usage: $0 [--kv memory|local|scale]" >&2; exit 2; }

CONTEXT="${CONTEXT:-agentic-cloud}"
NS="${NS:-serverless-harness}"
RUN_ID="${RUN_ID:-swebench-$(date +%Y%m%d-%H%M%S)}"
INSTANCE="${INSTANCE:-django__django-13410}"
AGENTS="${AGENTS:-1}"
SANDBOXES="${SANDBOXES:-$AGENTS}"
WORKSPACE="${WORKSPACE:-scale}"

case "$WORKSPACE" in
  scale) storage_class=ibm-scale-csi ;;
  local) storage_class=local-path ;;
  *) echo "WORKSPACE must be scale or local" >&2; exit 2 ;;
esac

if [ "$KV" = scale ]; then
  CONTEXT="$CONTEXT" "$ROOT/experiments/agentic-scale/lib/prepare-scale-kv.sh"
fi
"$ROOT/experiments/agentic-scale/lib/set-kv-mode.sh" "$KV"

CONTEXT="$CONTEXT" NS="$NS" RUN_ID="$RUN_ID" INSTANCE_ID="$INSTANCE" \
MODEL="${MODEL:-nvidia/nemotron-3-ultra}" STORAGE_CLASS="$storage_class" \
WORKSPACE_SIZE="${WORKSPACE_SIZE:-20Gi}" POOL_SIZE="$SANDBOXES" CONCURRENCY="$AGENTS" \
PROVISIONER=context-service EVALUATE="${EVALUATE:-1}" \
KSVC_URL="${KSVC_URL:-https://serverless-harness.163-75-85-180.sslip.io}" \
"$ROOT/experiments/agentic-scale/lib/run-one.sh"
