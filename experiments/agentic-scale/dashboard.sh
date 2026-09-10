#!/usr/bin/env bash
# Small, read-only terminal dashboard for this experiment's swebench-run.sh.
set -u

NS="${NS:-serverless-harness}"
CONTEXT="${CONTEXT:-agentic-cloud}"
RUN_ID="${1:-${RUN_ID:-demo1}}"
INTERVAL="${INTERVAL:-2}"
POOL="$(printf '%s' "$RUN_ID" | tr '[:upper:]_' '[:lower:]-' | cut -c1-48)"
POOL="swe-$POOL"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

kubectl() { command kubectl --context "$CONTEXT" "$@"; }

if [ "${SWEBENCH_DASHBOARD_FRAME:-0}" != 1 ]; then
  command -v watch >/dev/null || { echo "missing required command: watch (brew install watch)" >&2; exit 2; }
  exec watch -t -c -n "$INTERVAL" env SWEBENCH_DASHBOARD_FRAME=1 \
    CONTEXT="$CONTEXT" NS="$NS" INTERVAL="$INTERVAL" "$SCRIPT" "$RUN_ID"
fi

line() { printf '%*s\n' 92 '' | tr ' ' -; }
section() { printf '\n\033[1;36m%s\033[0m\n' "$1"; }

printf '\033[1;1H\033[2J'
printf '\033[1mSWE-bench Kubernetes dashboard\033[0m  run=%s  pool=%s  %s\n' "$RUN_ID" "$POOL" "$(date '+%H:%M:%S')"
line

section 'SANDBOX / POD / PVC'
{
  kubectl -n "$NS" get sandboxes,pods,persistentvolumeclaims --show-kind --no-headers 2>/dev/null \
    | awk -v pool="$POOL" 'index($0, pool)'
} || true

section 'KEDA AGENT WORKERS'
{
  kubectl -n "$NS" get jobs -l scaledjob.keda.sh/name=leaf-worker --sort-by=.metadata.creationTimestamp \
    --no-headers 2>/dev/null | tail -n 5
} || true
printf 'queue stream entries: '
kubectl -n "$NS" exec deploy/redis -- redis-cli XLEN leaf-queue 2>/dev/null || printf 'unavailable\n'

section 'SANDBOX /workspace AND REPOSITORY'
POD="$(kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
  | awk -v pool="$POOL" 'index($1,pool) && $2=="Running" {print $1; exit}')"
if [ -n "$POD" ]; then
  printf 'pod: %s\n' "$POD"
  # shellcheck disable=SC2016 # This script intentionally expands inside the sandbox container.
  kubectl -n "$NS" exec "$POD" -c sandbox -- sh -c '
    printf "\n/workspace\n"
    ls -la /workspace 2>/dev/null
    repo=$(find /workspace -mindepth 1 -maxdepth 1 -type d -name "co-*" 2>/dev/null | head -n 1)
    if [ -n "$repo" ]; then
      printf "\n%s\n" "$repo"
      ls -la "$repo" 2>/dev/null | head -n 20
    else
      printf "\n(repository checkout has not appeared yet)\n"
    fi
  ' 2>/dev/null || printf '(workspace unavailable)\n'
else
  printf '(waiting for sandbox pod)\n'
fi

section 'RECENT WORKER LOGS'
{
  kubectl -n "$NS" logs -l scaledjob.keda.sh/name=leaf-worker --all-containers=true \
    --prefix=true --tail=40 --max-log-requests=10 2>/dev/null \
    | grep -F "$RUN_ID" | tail -n 8
} || printf '(waiting for worker logs)\n'

section 'LIVE PI AGENT ACTIVITY'
SESSION="${RUN_ID}-1"
EVENT_COUNT="$(kubectl -n "$NS" exec deploy/redis -- redis-cli XLEN "session:$SESSION" 2>/dev/null || true)"
printf 'session: %s  events: %s\n' "$SESSION" "${EVENT_COUNT:-waiting}"
EVENTS="$(kubectl -n "$NS" exec deploy/redis -- redis-cli --json \
  XREVRANGE "session:$SESSION" + - COUNT 16 2>/dev/null || true)"
if jq -e 'length > 0' >/dev/null 2>&1 <<<"$EVENTS"; then
  jq -r '
    def record:
      .[1] as $fields |
      reduce range(0; ($fields|length); 2) as $i ({}; .[$fields[$i]] = $fields[$i+1]);
    reverse[] | record | .entry | fromjson? | .message? // empty |
    if .role == "assistant" then
      . as $message | .content[]? |
      if .type == "toolCall" then
        "→ " + .name + ": " +
          ((.arguments.command // .arguments.path // (.arguments|tostring)) | split("\n")[0] | .[0:110])
      elif .type == "text" then
        "agent: " + ((.text // "") | gsub("[\\n\\r]+"; " ") | .[0:110])
      else empty end
    elif .role == "toolResult" then
      "← " + (.toolName // "tool") + (if .isError then " ERROR: " else ": " end) +
        (([.content[]?.text // empty] | join(" ")) | gsub("[\\n\\r]+"; " ") | .[0:110])
    else empty end
  ' <<<"$EVENTS" 2>/dev/null | tail -n 10
else
  printf '(waiting for agent events)\n'
fi

section 'LOCAL RESULT'
RESULTS="${RESULTS_ROOT:-/tmp/serverless-harness-swebench}/$RUN_ID"
if [ -f "$RESULTS/summary.json" ]; then
  jq -r '"provision=" + (.provisionMs|tostring) + "ms  tasks=" + (.tasks|length|tostring),
    (.tasks[] | "#\(.ordinal) \(.status)  duration=\(.durationMs)ms  patch=\(.patchBytes)B  tokens=\(.usage.total // "pending")")' \
    "$RESULTS/summary.json" 2>/dev/null || true
elif [ -d "$RESULTS" ]; then
  printf 'run active; results: %s\n' "$RESULTS"
else
  printf '(waiting for %s)\n' "$RESULTS"
fi
