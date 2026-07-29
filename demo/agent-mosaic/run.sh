#!/usr/bin/env bash
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUNT="${COUNT:-20}"
SANDBOXES="${SANDBOXES:-5}"
PARALLEL="${PARALLEL:-10}"
CLAIM="${CLAIM:-agent-mosaic-workspace}"
MODEL="${MODEL:-meta-llama/Llama-3.3-70B-Instruct}"
KUBE_CONTEXT="${KUBE_CONTEXT:-agentic-cloud}"
NAMESPACE="${NAMESPACE:-serverless-harness}"
KAGENTI_BASE="${KAGENTI_BASE:-https://serverless-harness.163-75-85-180.sslip.io}"
KAGENTI_AUTH_HEADER="${KAGENTI_AUTH_HEADER:-x-sh-auth}"
RUN_ID="${RUN_ID:-mosaic-$(date +%Y%m%d-%H%M%S)}"
WRITER_ID="${RUN_ID}-writer"
READER_ID="${RUN_ID}-readers"
OUT="$DEMO_DIR/output/$RUN_ID"

for command in curl jq kubectl python3; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done
[[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "COUNT must be a positive integer" >&2; exit 1; }
[[ "$SANDBOXES" =~ ^[1-9][0-9]*$ ]] || { echo "SANDBOXES must be a positive integer" >&2; exit 1; }
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "PARALLEL must be a positive integer" >&2; exit 1; }

if [ -z "${KAGENTI_AUTH_VALUE:-}" ]; then
  KAGENTI_AUTH_VALUE="$(kubectl --context "$KUBE_CONTEXT" -n kagenti-system get authorizationpolicy \
    serverless-harness-require-header -o jsonpath='{.spec.rules[0].when[0].notValues[0]}')"
fi
AUTH=(-H "$KAGENTI_AUTH_HEADER: $KAGENTI_AUTH_VALUE")
mkdir -p "$OUT/requests" "$OUT/responses"

update_state() {
  local stage="$1" state="$2"
  jq -n --arg runId "$RUN_ID" --arg writerId "$WRITER_ID" --arg readerId "$READER_ID" \
    --arg claim "$CLAIM" --arg model "$MODEL" --arg stage "$stage" --arg state "$state" \
    --argjson count "$COUNT" --argjson sandboxes "$SANDBOXES" --argjson parallel "$PARALLEL" \
    --argjson updated "$(date +%s)" \
    '{runId:$runId,writerId:$writerId,readerId:$readerId,claim:$claim,model:$model,count:$count,sandboxes:$sandboxes,parallel:$parallel,stage:$stage,state:$state,updated:$updated}' \
    > "$OUT/state.json.tmp"
  mv "$OUT/state.json.tmp" "$OUT/state.json"
}
event() {
  printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/events.log"
}
update_state "starting" "running"

delete_workload() {
  curl -fsS -X DELETE "${AUTH[@]}" "$KAGENTI_BASE/workloads/$1" >/dev/null 2>&1 || true
}
cleanup() {
  if [ "${KEEP_POOLS:-0}" = "1" ]; then return; fi
  delete_workload "$WRITER_ID"
  delete_workload "$READER_ID"
}
finish() {
  local code="$1"
  trap - EXIT
  cleanup
  if [ "$code" -ne 0 ]; then
    update_state "failed" "failed"
    event "Run failed with exit code $code"
  fi
  exit "$code"
}
trap 'finish $?' EXIT

wait_workload() {
  local id="$1" status=""
  for _ in $(seq 1 90); do
    status="$(curl -fsS "${AUTH[@]}" "$KAGENTI_BASE/workloads/$id")"
    [ "$(jq -r '.status' <<<"$status")" = "ready" ] && return
    sleep 2
  done
  echo "workload $id did not become ready: $status" >&2
  exit 1
}

create_claim_workload() {
  local id="$1" replicas="$2" read_only="$3"
  jq -n --arg name "$id" --arg claim "$CLAIM" --argjson n "$replicas" --argjson ro "$read_only" \
    '{name:$name,sandboxes:$n,workspace:{claimName:$claim,readOnly:$ro}}' |
    curl -fsS -X POST "${AUTH[@]}" -H 'Content-Type: application/json' -d @- "$KAGENTI_BASE/workloads" >/dev/null
  wait_workload "$id"
}

event "Producer: create one read-write sandbox"
update_state "producer" "running"
create_claim_workload "$WRITER_ID" 1 false
WRITER_POD="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pod \
  -l "context.rossoctl.io/pool=$WRITER_ID" -o jsonpath='{.items[0].metadata.name}')"
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" exec -i "$WRITER_POD" -- \
  sh -c 'cat > /workspace/mosaic-seed.md' < "$DEMO_DIR/seed.md"

PRODUCER_REQUEST="$(jq -n --rawfile seed "$DEMO_DIR/seed.md" '{
  prompt:("You are the creative director for a collaborative artwork. Do not call tools and do not describe your task. Write exactly five vivid sentences forming the actual world brief. Sentence 1 names the world. Sentence 2 establishes its atmosphere. Sentence 3 gives a color palette. Sentence 4 names recurring visual symbols. Sentence 5 gives artists one surprising constraint. Output only those five sentences.\n\nCREATIVE SEED:\n"+$seed)
}')"
PRODUCER_RESPONSE="$(curl -fsS -X POST "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d "$PRODUCER_REQUEST" "$KAGENTI_BASE/turn")"
BRIEF="$(jq -er '.response' <<<"$PRODUCER_RESPONSE")"
printf '# Agent-generated world brief\n\n%s\n' "$BRIEF" | kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" \
  exec -i "$WRITER_POD" -- sh -c 'cat > /workspace/world-brief.md'
printf '%s\n' "$PRODUCER_RESPONSE" > "$OUT/producer.json"
printf '%s\n' "$BRIEF" > "$OUT/world-brief.md"
event "Producer wrote world-brief.md to GPFS"
update_state "handoff" "running"
delete_workload "$WRITER_ID"

event "Consumers: $COUNT interpretations across $SANDBOXES read-only sandboxes"
update_state "consumers" "running"
create_claim_workload "$READER_ID" "$SANDBOXES" true
roles=(botanist astronomer choreographer architect poet cartographer musician ecologist futurist storyteller)
for i in $(seq 1 "$COUNT"); do
  number="$(printf '%03d' "$i")"
  role="${roles[$(( (i - 1) % ${#roles[@]} ))]}"
  jq -n --arg sid "$RUN_ID/tile-$number" --arg wid "$READER_ID" --arg model "$MODEL" \
    --arg id "tile-$number" --arg role "$role" --arg n "$number" '{
      workloadId:$wid,sessionId:$sid,model:$model,workspaceRef:"/workspace",maxTurns:3,
      item:{item_id:$id,file:"world-brief.md",pattern:("As tile "+$n+" and a "+$role+", imagine one unique living symbol that belongs in this world. In the submit_verdict reason, name it and describe its color and motion in one vivid sentence. Never copy these instructions or an output template. Do not modify the source artifact.")}
    }' > "$OUT/requests/$number.json"
done

export KAGENTI_BASE KAGENTI_AUTH_HEADER KAGENTI_AUTH_VALUE OUT
find "$OUT/requests" -name '*.json' -print0 | xargs -0 -n 1 -P "$PARALLEL" sh -c '
  request="$1"; name="$(basename "$request")"
  response="$OUT/responses/$name"
  tmp="$response.tmp"
  headers="$response.headers"
  attempt=1
  max_attempts=20
  while [ "$attempt" -le "$max_attempts" ]; do
    status="$(curl -sS -o "$tmp" -D "$headers" -w "%{http_code}" -X POST \
      -H "$KAGENTI_AUTH_HEADER: $KAGENTI_AUTH_VALUE" -H "Content-Type: application/json" \
      -d @"$request" "$KAGENTI_BASE/runs")" && curl_code=0 || curl_code=$?
    if [ "$curl_code" -eq 0 ] && [ "$status" = 200 ]; then
      mv "$tmp" "$response"
      rm -f "$headers"
      exit 0
    fi
    case "$status" in
      000|429|502|503|504)
        delay="$(awk '\''BEGIN{IGNORECASE=1} /^Retry-After:/{gsub("\\r", "", $2); print $2}'\'' "$headers" | tail -n 1)"
        case "$delay" in ""|*[!0-9]*) delay=5 ;; esac
        printf "%s: harness busy (%s), retry %d/%d in %ss\n" "$name" "$status" "$attempt" "$max_attempts" "$delay" >&2
        sleep "$delay"
        ;;
      *)
        printf "%s: request failed (HTTP %s, curl %s): " "$name" "$status" "$curl_code" >&2
        cat "$tmp" >&2
        exit 1
        ;;
    esac
    attempt=$((attempt + 1))
  done
  printf "%s: exhausted %d attempts\n" "$name" "$max_attempts" >&2
  exit 1
' sh

jq -s '.' "$OUT"/responses/*.json > "$OUT/responses.json"
update_state "render" "running"
python3 "$DEMO_DIR/render.py" "$OUT/responses.json" "$OUT/mosaic.html"
delete_workload "$READER_ID"

update_state "complete" "complete"
event "Mosaic complete"
echo "World brief: $OUT/world-brief.md"
echo "Agent responses: $OUT/responses.json"
echo "Animated mosaic: $OUT/mosaic.html"
