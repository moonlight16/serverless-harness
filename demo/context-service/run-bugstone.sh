#!/usr/bin/env bash
# Follow-up demo: ask SH to allocate a Context Service workload, then run the
# unchanged BugStone GPFS demo inside that workload.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC_DEMO="$DEMO_DIR/../gpfs-scale/run-bugstone.sh"
ACT="${1:-}"
FIXTURE="${2:-tests/fixtures/smoke-python}"

case "$ACT" in
  act1|act2) ;;
  *) echo "Usage: $0 act1|act2 [fixture]" >&2; exit 1 ;;
esac

KUBE_CONTEXT="${KUBE_CONTEXT:-agentic-cloud}"
KAGENTI_BASE="${KAGENTI_BASE:-https://serverless-harness.163-75-85-180.sslip.io}"
KAGENTI_AUTH_HEADER="${KAGENTI_AUTH_HEADER:-x-sh-auth}"
if [ -z "${KAGENTI_AUTH_VALUE:-}" ]; then
  KAGENTI_AUTH_VALUE="$(kubectl --context "$KUBE_CONTEXT" -n kagenti-system get authorizationpolicy \
    serverless-harness-require-header -o jsonpath='{.spec.rules[0].when[0].notValues[0]}')"
fi

WORKLOAD_ID="${WORKLOAD_ID:-bugstone-$(date +%Y%m%d-%H%M%S)}"
WORKLOAD_URL="$KAGENTI_BASE/workloads/$WORKLOAD_ID"

cleanup() {
  if [ "${KEEP_POOL:-0}" = "1" ]; then
    echo "--- keeping workload pool: $WORKLOAD_ID ---"
    return
  fi
  echo "--- release workload: $WORKLOAD_ID ---"
  curl -fsS -X DELETE -H "$KAGENTI_AUTH_HEADER: $KAGENTI_AUTH_VALUE" "$WORKLOAD_URL" || true
}
trap cleanup EXIT

echo "--- create workload: $WORKLOAD_ID ---"
curl -fsS -X POST \
  -H "$KAGENTI_AUTH_HEADER: $KAGENTI_AUTH_VALUE" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$WORKLOAD_ID\",\"sandboxes\":3,\"workspace\":{\"shared\":true,\"size\":\"5Gi\",\"storageClass\":\"ibm-scale-csi\"}}" \
  "$KAGENTI_BASE/workloads"
echo

echo "--- wait for workload pool ---"
for _ in $(seq 1 60); do
  STATUS="$(curl -fsS -H "$KAGENTI_AUTH_HEADER: $KAGENTI_AUTH_VALUE" "$WORKLOAD_URL")"
  READY="$(printf '%s' "$STATUS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))')"
  printf '%s\n' "$STATUS"
  [ "$READY" = "ready" ] && break
  sleep 2
done
[ "$READY" = "ready" ] || { echo "workload did not become ready" >&2; exit 1; }

export KAGENTI_BASE KAGENTI_AUTH_HEADER KAGENTI_AUTH_VALUE
export KAGENTI_WORKLOAD_ID="$WORKLOAD_ID"
export KAGENTI_POOL_SELECTOR="context.rossoctl.io/pool=$WORKLOAD_ID"
export BUGSTONE_EXTRA_PATCH="$DEMO_DIR/bugstone-workload.patch"

"$STATIC_DEMO" "$ACT" "$FIXTURE"
