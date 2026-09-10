#!/usr/bin/env bash
# Internal single-instance runner: provision -> submit -> collect -> evaluate -> clean up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

CONTEXT="${CONTEXT:-agentic-cloud}"
NS="${NS:-serverless-harness}"
KSVC="${KSVC:-serverless-harness}"
INSTANCE_ID="${INSTANCE_ID:-django__django-13410}"
CONCURRENCY="${CONCURRENCY:-1}"
POOL_SIZE="${POOL_SIZE:-$CONCURRENCY}"
PROVISIONER="${PROVISIONER:-static}" # static | context-service
MODEL="${MODEL:-}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
WORKSPACE_SIZE="${WORKSPACE_SIZE:-20Gi}"
POLL_TIMEOUT="${POLL_TIMEOUT:-900}"
EVALUATE="${EVALUATE:-1}"
REQUIRE_PATCH="${REQUIRE_PATCH:-1}"
KEEP_RESOURCES="${KEEP_RESOURCES:-0}"
DECK="${DECK:-$ROOT/experiments/swebench/deck.json}"
RUN_ID="${RUN_ID:-swebench-e2e-$(date +%Y%m%d-%H%M%S)}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/serverless-harness-swebench/$RUN_ID}"
CS_PORT="${CS_PORT:-18081}"

# Keep every cluster operation on the demo cluster without changing the user's current context.
kubectl() { command kubectl --context "$CONTEXT" "$@"; }

case "$PROVISIONER" in static|context-service) ;; *) echo "PROVISIONER must be static or context-service" >&2; exit 2 ;; esac
case "$CONCURRENCY:$POOL_SIZE" in *[!0-9:]*|0:*|*:0) echo "CONCURRENCY and POOL_SIZE must be positive integers" >&2; exit 2 ;; esac
case "$EVALUATE:$REQUIRE_PATCH:$KEEP_RESOURCES" in *[!01:]*) echo "EVALUATE, REQUIRE_PATCH, and KEEP_RESOURCES must be 0 or 1" >&2; exit 2 ;; esac

for command in kubectl jq curl python3; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 2; }
done
if [ "$EVALUATE" = 1 ]; then
  command -v docker >/dev/null || { echo "missing required command: docker" >&2; exit 2; }
fi
kubectl -n "$NS" get ksvc "$KSVC" >/dev/null
kubectl -n "$NS" get scaledjob/leaf-worker >/dev/null
if [ "$PROVISIONER" = context-service ]; then
  kubectl -n "$NS" get deployment/context-service service/context-service >/dev/null
fi

INSTANCE="$(jq -c --arg id "$INSTANCE_ID" '.instances[] | select(.instance_id==$id)' "$DECK")"
[ -n "$INSTANCE" ] || { echo "instance not found in $DECK: $INSTANCE_ID" >&2; exit 2; }
REPO="$(jq -r '.repo' <<<"$INSTANCE")"
BASE_COMMIT="$(jq -r '.base_commit' <<<"$INSTANCE")"
ENV_KEY="$(jq -r '.env_key' <<<"$INSTANCE")"
ENV_DIR="${ENV_KEY%:latest}"
IMAGE_ID="$(printf '%s' "$INSTANCE_ID" | sed 's/__/\_1776\_/g' | tr '[:upper:]' '[:lower:]')"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-docker.io/swebench/sweb.eval.x86_64.${IMAGE_ID}:latest}"
POOL="$(printf '%s' "$RUN_ID" | tr '[:upper:]_' '[:lower:]-' | cut -c1-48)"
POOL="swe-${POOL}"
SELECTOR="sh.kagenti.io/sandbox-pool=$POOL"

mkdir -p "$RESULTS_DIR/responses"
printf '%s\n' "$INSTANCE" >"$RESULTS_DIR/instance.json"

WORKER_SELECTOR_INDEX=""
ORIGINAL_WORKER_SELECTOR=""
ORIGINAL_CS_IMAGE=""
CS_PROXY_PID=""
POOL_CREATED=0

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ -n "$WORKER_SELECTOR_INDEX" ] && [ -n "$ORIGINAL_WORKER_SELECTOR" ]; then
    patch="$(jq -nc --arg path "/spec/jobTargetRef/template/spec/containers/0/env/$WORKER_SELECTOR_INDEX/value" --arg value "$ORIGINAL_WORKER_SELECTOR" '[{"op":"replace","path":$path,"value":$value}]')"
    kubectl -n "$NS" patch scaledjob leaf-worker --type=json -p="$patch" >/dev/null 2>&1 || true
  fi
  if [ "$KEEP_RESOURCES" != 1 ] && [ "$POOL_CREATED" = 1 ]; then
    if [ "$PROVISIONER" = context-service ]; then
      curl -sf -X DELETE "http://127.0.0.1:$CS_PORT/v1/sandbox-pools/$POOL" >/dev/null 2>&1 || true
      # Current Retain semantics can leave the generated pods/PVCs after the allocation record and
      # Sandbox objects are gone. The run-specific label makes this fallback precise and bounded.
      kubectl -n "$NS" delete sandbox,pod,pvc -l "context.rossoctl.io/pool=$POOL" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    else
      for i in $(seq 0 $((POOL_SIZE - 1))); do
        # The pool selector is a pod-template label, not Sandbox metadata. Delete exact names and
        # never let cleanup block indefinitely on Kubernetes garbage collection.
        kubectl -n "$NS" delete sandbox "$POOL-$i" --ignore-not-found --wait=false >/dev/null 2>&1 || true
        kubectl -n "$NS" delete pod "$POOL-$i" --ignore-not-found --wait=false >/dev/null 2>&1 || true
        kubectl -n "$NS" delete pvc "workspace-$POOL-$i" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      done
    fi
  fi
  if [ -n "$ORIGINAL_CS_IMAGE" ]; then
    kubectl -n "$NS" set env deployment/context-service "CS_SANDBOX_IMAGE=$ORIGINAL_CS_IMAGE" >/dev/null 2>&1 || true
    kubectl -n "$NS" rollout status deployment/context-service --timeout=180s >/dev/null 2>&1 || true
  fi
  if [ -n "$CS_PROXY_PID" ]; then
    kill "$CS_PROXY_PID" >/dev/null 2>&1 || true
    wait "$CS_PROXY_PID" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

echo "Run: $RUN_ID"
echo "Instance: $INSTANCE_ID"
echo "Provisioner: $PROVISIONER; pool size: $POOL_SIZE; concurrency: $CONCURRENCY"
echo "Results: $RESULTS_DIR"
echo "Dashboard: ./experiments/agentic-scale/dashboard.sh $RUN_ID"
echo "[1/4] Creating Sandbox + $STORAGE_CLASS workspace"

provision_started="$(python3 -c 'import time; print(int(time.time()*1000))')"
if [ "$PROVISIONER" = static ]; then
  for i in $(seq 0 $((POOL_SIZE - 1))); do
    kubectl apply -f - <<EOF
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: $POOL-$i
  namespace: $NS
spec:
  shutdownPolicy: Delete
  volumeClaimTemplates:
    - metadata:
        name: workspace
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: $STORAGE_CLASS
        resources:
          requests:
            storage: $WORKSPACE_SIZE
  podTemplate:
    metadata:
      labels:
        sh.kagenti.io/sandbox-pool: $POOL
    spec:
      containers:
        - name: sandbox
          image: $SANDBOX_IMAGE
          imagePullPolicy: IfNotPresent
          command: ["sleep", "infinity"]
          workingDir: /workspace
          resources:
            requests: {cpu: "250m", memory: "512Mi"}
            limits: {memory: "4Gi"}
          volumeMounts:
            - name: workspace
              mountPath: /workspace
EOF
  done
  POOL_CREATED=1
else
  ORIGINAL_CS_IMAGE="$(kubectl -n "$NS" get deployment context-service -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="CS_SANDBOX_IMAGE") | .value')"
  kubectl -n "$NS" set env deployment/context-service "CS_SANDBOX_IMAGE=$SANDBOX_IMAGE" >/dev/null
  kubectl -n "$NS" rollout status deployment/context-service --timeout=180s >/dev/null
  kubectl -n "$NS" port-forward svc/context-service "$CS_PORT:8080" >"$RESULTS_DIR/context-service-proxy.log" 2>&1 &
  CS_PROXY_PID=$!
  for _ in $(seq 1 30); do
    curl -sf "http://127.0.0.1:$CS_PORT/healthz" >/dev/null 2>&1 && break
    kill -0 "$CS_PROXY_PID" >/dev/null 2>&1 || { echo "Context Service port-forward stopped; see $RESULTS_DIR/context-service-proxy.log" >&2; exit 1; }
    sleep 1
  done
  request="$(jq -nc --arg name "$POOL" --arg size "$WORKSPACE_SIZE" --arg sc "$STORAGE_CLASS" --argjson replicas "$POOL_SIZE" '{name:$name,replicas:$replicas,workspace:{size:$size,accessMode:"ReadWriteOnce",storageClass:$sc}}')"
  curl -sf -H 'Content-Type: application/json' -d "$request" "http://127.0.0.1:$CS_PORT/v1/sandbox-pools" >"$RESULTS_DIR/pool.json"
  POOL_CREATED=1
  SELECTOR="context.rossoctl.io/pool=$POOL"
fi

ready_deadline=$(( $(date +%s) + 600 ))
while [ "$(kubectl -n "$NS" get pods -l "$SELECTOR" -o json 2>/dev/null | jq '.items|length')" -lt "$POOL_SIZE" ]; do
  [ "$(date +%s)" -lt "$ready_deadline" ] || { echo "timed out waiting for $POOL_SIZE sandbox pods matching $SELECTOR" >&2; exit 1; }
  sleep 2
done
kubectl -n "$NS" wait --for=condition=Ready pod -l "$SELECTOR" --timeout=600s >/dev/null
provision_finished="$(python3 -c 'import time; print(int(time.time()*1000))')"

# Preserve proof of the ephemeral workspace binding before normal cleanup removes the PVC.
: >"$RESULTS_DIR/workspace.jsonl"
while IFS= read -r claim; do
  [ -n "$claim" ] || continue
  kubectl -n "$NS" get pvc "$claim" -o json | jq -c \
    '{name:.metadata.name,status:.status.phase,storageClass:.spec.storageClassName,volume:.spec.volumeName}' \
    >>"$RESULTS_DIR/workspace.jsonl"
done < <(kubectl -n "$NS" get pods -l "$SELECTOR" -o json | \
  jq -r '.items[].spec.volumes[]?.persistentVolumeClaim.claimName // empty' | sort -u)
jq -s . "$RESULTS_DIR/workspace.jsonl" >"$RESULTS_DIR/workspace.json"

# Official per-instance images contain /testbed and its conda environment. Expose them under the
# paths expected by the Serverless Harness SWE-bench setup code.
echo "[2/4] Preparing repository $REPO"
for pod in $(kubectl -n "$NS" get pods -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  # shellcheck disable=SC2016 # Variables in the single-quoted script are arguments inside the pod.
  kubectl -n "$NS" exec "$pod" -- sh -c '
    set -eu
    repo=$1; base=$2; envdir=$3
    mkdir -p "/repos/$(dirname "$repo")"
    git clone --bare /testbed "/repos/$repo.git" >/dev/null 2>&1
    git --git-dir="/repos/$repo.git" cat-file -e "$base^{commit}"
    ln -sfn /opt/miniconda3/envs/testbed "/opt/miniconda3/envs/$envdir"
  ' _ "$REPO" "$BASE_COMMIT" "$ENV_DIR"
done

WORKER_SELECTOR_INDEX="$(kubectl -n "$NS" get scaledjob leaf-worker -o json | jq -r '.spec.jobTargetRef.template.spec.containers[0].env | to_entries[] | select(.value.name=="KAGENTI_SANDBOX_POOL_SELECTOR") | .key')"
ORIGINAL_WORKER_SELECTOR="$(kubectl -n "$NS" get scaledjob leaf-worker -o json | jq -r --argjson i "$WORKER_SELECTOR_INDEX" '.spec.jobTargetRef.template.spec.containers[0].env[$i].value')"
worker_patch="$(jq -nc --arg path "/spec/jobTargetRef/template/spec/containers/0/env/$WORKER_SELECTOR_INDEX/value" --arg value "$SELECTOR" '[{"op":"replace","path":$path,"value":$value}]')"
kubectl -n "$NS" patch scaledjob leaf-worker --type=json -p="$worker_patch" >/dev/null

if [ -z "$MODEL" ]; then
  MODEL="$(kubectl -n "$NS" get ksvc "$KSVC" -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="SH_MODEL") | .value')"
fi
KSVC_URL="${KSVC_URL:-}"
if [ -z "$KSVC_URL" ]; then
  route_host="$(kubectl -n "$NS" get httproute "$KSVC" -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || true)"
  [ -n "$route_host" ] || { echo "Set KSVC_URL: no HTTPRoute hostname found" >&2; exit 2; }
  KSVC_URL="https://$route_host"
fi

pids=()
solve_started="$(date +%s)"
echo "[3/4] Agent solving $INSTANCE_ID..."
for i in $(seq 1 "$CONCURRENCY"); do
  sid="$RUN_ID-$i"
  (
    started="$(python3 -c 'import time; print(int(time.time()*1000))')"
    deadline=$(( $(date +%s) + POLL_TIMEOUT ))
    body="$(jq -c --arg sid "$sid" --arg model "$MODEL" '. + {sessionId:$sid,kind:"solve",repoUrl:("/repos/"+.repo+".git"),ref:.base_commit,env_key:.env_key,problemStatement:.problem_statement,model:$model,maxTurns:8,async:true} | del(.instance_id,.repo,.base_commit,.environment_setup_commit,.version,.test_patch,.fail_to_pass,.pass_to_pass,.test_cmd,.test_directives,.test_runtime_ms,.weight_bucket)' <<<"$INSTANCE")"
    curl -skf --max-time 30 -H 'Content-Type: application/json' -d "$body" "$KSVC_URL/runs" >"$RESULTS_DIR/responses/$i.accepted.json"
    while :; do
      encoded_sid="$(jq -rn --arg value "$sid" '$value|@uri')"
      response="$(curl -skf --max-time 15 "$KSVC_URL/runs/status?sessionId=$encoded_sid" || true)"
      status="$(jq -r '.status // empty' <<<"$response" 2>/dev/null || true)"
      case "$status" in solved|failed|done|aborted) break ;; esac
      [ "$(date +%s)" -lt "$deadline" ] || { printf 'timed out after %ss\n' "$POLL_TIMEOUT" >"$RESULTS_DIR/responses/$i.error"; exit 1; }
      sleep 3
    done
    finished="$(python3 -c 'import time; print(int(time.time()*1000))')"
    printf '%s\n' "$response" >"$RESULTS_DIR/responses/$i.json"
    jq -nc --argjson ordinal "$i" --arg sid "$sid" --arg status "$status" --argjson started "$started" --argjson finished "$finished" --argjson duration "$((finished-started))" --argjson patchBytes "$(jq -r '(.patch // "")|length' <<<"$response")" --argjson usage "$(jq -c '.usage // null' <<<"$response")" '{ordinal:$ordinal,sessionId:$sid,status:$status,startedMs:$started,finishedMs:$finished,durationMs:$duration,patchBytes:$patchBytes,usage:$usage}' >"$RESULTS_DIR/responses/$i.metrics.json"
    [ "$status" = solved ] || { printf 'terminal status: %s\n' "$status" >"$RESULTS_DIR/responses/$i.error"; exit 1; }
    if [ "$REQUIRE_PATCH" = 1 ] && [ "$(jq -r '(.patch // "")|length' <<<"$response")" -eq 0 ]; then
      echo "agent returned an empty patch" >"$RESULTS_DIR/responses/$i.error"
      exit 1
    fi
  ) &
  pids+=("$!")
done

failed=0
while :; do
  running=0
  for pid in "${pids[@]}"; do
    kill -0 "$pid" >/dev/null 2>&1 && running=$((running + 1))
  done
  [ "$running" -gt 0 ] || break
  sleep 20
  elapsed=$(( $(date +%s) - solve_started ))
  complete="$(find "$RESULTS_DIR/responses" -name '*.metrics.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
  printf '[3/4] Agent solving... %d/%d complete · %dm %02ds\n' \
    "$complete" "$CONCURRENCY" "$((elapsed / 60))" "$((elapsed % 60))"
done
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
[ "$failed" = 0 ] || { echo "one or more tasks failed; see $RESULTS_DIR/responses" >&2; exit 1; }

# Some deployed Pi builds omit inline usage. Recover the authoritative totals from the durable
# Redis session stream, matching the established E1/E6 benchmark accounting path.
for i in $(seq 1 "$CONCURRENCY"); do
  metrics="$RESULTS_DIR/responses/$i.metrics.json"
  if [ "$(jq -r '.usage == null' "$metrics")" = true ]; then
    sid="$(jq -r '.sessionId' "$metrics")"
    recovered="$(kubectl -n "$NS" exec deploy/redis -- redis-cli XRANGE "session:$sid" - + 2>/dev/null \
      | SID="$sid" python3 "$ROOT/deploy/knative/session-usage.py" 2>/dev/null || true)"
    if jq -e . >/dev/null 2>&1 <<<"$recovered"; then
      jq --argjson usage "$recovered" '.usage=$usage' "$metrics" >"$metrics.tmp"
      mv "$metrics.tmp" "$metrics"
    fi
  fi
done

: >"$RESULTS_DIR/predictions.jsonl"
: >"$RESULTS_DIR/metrics.jsonl"
: >"$RESULTS_DIR/usage.jsonl"
for i in $(seq 1 "$CONCURRENCY"); do
  response="$RESULTS_DIR/responses/$i.json"
  jq -c --arg id "$INSTANCE_ID" --arg model "$MODEL" '{instance_id:$id,model_name_or_path:$model,model_patch:(.patch // "")}' "$response" >>"$RESULTS_DIR/predictions.jsonl"
  jq -c --arg id "$INSTANCE_ID" '. + {instanceId:$id}' "$RESULTS_DIR/responses/$i.metrics.json" >>"$RESULTS_DIR/metrics.jsonl"
  jq -c --arg id "$INSTANCE_ID" --argjson ordinal "$i" 'select(.usage != null) | {instanceId:$id,ordinal:$ordinal,usage:.usage}' "$RESULTS_DIR/responses/$i.metrics.json" >>"$RESULTS_DIR/usage.jsonl"
done

jq -s --arg run "$RUN_ID" --arg provisioner "$PROVISIONER" --arg instance "$INSTANCE_ID" --arg model "$MODEL" --arg selector "$SELECTOR" --argjson concurrency "$CONCURRENCY" --argjson poolSize "$POOL_SIZE" --argjson provisionMs "$((provision_finished-provision_started))" '{runId:$run,provisioner:$provisioner,instanceId:$instance,model:$model,selector:$selector,concurrency:$concurrency,poolSize:$poolSize,provisionMs:$provisionMs,tasks:.}' "$RESULTS_DIR"/responses/*.metrics.json >"$RESULTS_DIR/summary.json"

jq -r '.tasks[] | "Solved: \(.status) · \(.durationMs / 1000 | floor)s · patch \(.patchBytes) bytes"' "$RESULTS_DIR/summary.json"

if [ "$EVALUATE" = 1 ]; then
  echo "[4/4] Evaluating patch with SWE-bench"
  INSTANCE_IDS="$INSTANCE_ID" RUN_ID="$RUN_ID" MAX_WORKERS=1 \
    PRED_A="$RESULTS_DIR/predictions.jsonl" PRED_B='' \
    LOG_DIR="$RESULTS_DIR/evaluation" VENV="${SWEBENCH_EVAL_VENV:-/tmp/swebench-eval-venv}" \
    bash "$ROOT/experiments/agentic-scale/lib/evaluate.sh" | tee "$RESULTS_DIR/evaluation.txt"
else
  echo "[4/4] Evaluation skipped"
fi

echo "Complete: $RESULTS_DIR"
