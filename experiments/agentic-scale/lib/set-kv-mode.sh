#!/usr/bin/env bash
# Select Nemotron's vLLM KV hierarchy: memory only, local NVMe, or Scale PVC.
set -euo pipefail

MODE="${1:?usage: $0 memory|local|scale}"
CONTEXT="${CONTEXT:-agentic-cloud}"
NS="${LLM_NS:-llm-d}"
DEPLOY="${LLM_DEPLOY:-ms-nvidia-nemotron-3-ultra-llm-d-modelservice-decode}"
CPU_BYTES="${KV_CPU_BYTES:-137438953472}"
LOCAL_PATH="${KV_LOCAL_PATH:-/mnt/llm-d-cache/nemotron-ultra}"
SCALE_PVC="${KV_SCALE_PVC:-nemotron-kv-cache-scale}"

case "$MODE" in memory|local|scale) ;; *) echo "KV mode must be memory, local, or scale" >&2; exit 2 ;; esac

wait_for_current_pod() {
  local selector generation observed revision hash pods
  selector="$(kubectl --context "$CONTEXT" -n "$NS" get deployment "$DEPLOY" \
    -o json | jq -r '.spec.selector.matchLabels | to_entries | map(.key+"="+.value) | join(",")')"
  generation="$(kubectl --context "$CONTEXT" -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.metadata.generation}')"
  for _ in $(seq 1 90); do
    read -r observed revision <<EOF
$(kubectl --context "$CONTEXT" -n "$NS" get deployment "$DEPLOY" \
  -o jsonpath='{.status.observedGeneration}{" "}{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || true)
EOF
    hash="$(kubectl --context "$CONTEXT" -n "$NS" get replicasets -l "$selector" -o json | \
      jq -r --arg revision "$revision" '.items[] | select(.metadata.annotations["deployment.kubernetes.io/revision"] == $revision) | .metadata.labels["pod-template-hash"]' | tail -n 1)"
    pods=0
    if [ -n "$hash" ]; then
      pods="$(kubectl --context "$CONTEXT" -n "$NS" get pods \
        -l "$selector,pod-template-hash=$hash" -o json | jq '.items | length')"
    fi
    if [ "${observed:-0}" -ge "$generation" ] 2>/dev/null && [ "$pods" -gt 0 ]; then break; fi
    sleep 2
  done
  [ -n "${hash:-}" ] && [ "${pods:-0}" -gt 0 ] || {
    echo "Could not identify the current Nemotron pod" >&2
    return 1
  }
  echo "Waiting for the active Nemotron pod to become ready..."
  kubectl --context "$CONTEXT" -n "$NS" wait --for=condition=Ready pod \
    -l "$selector,pod-template-hash=$hash" --timeout=30m >/dev/null
}

current="$(kubectl --context "$CONTEXT" -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.metadata.annotations.agentic-scale\.rossoctl\.io/kv-mode}' 2>/dev/null || true)"
if [ "$current" = "$MODE" ]; then
  echo "KV mode configured: $MODE"
  wait_for_current_pod
  echo "KV mode ready: $MODE"
  exit 0
fi

if [ "$MODE" = scale ]; then
  kubectl --context "$CONTEXT" -n "$NS" get pvc "$SCALE_PVC" >/dev/null || {
    echo "Missing Scale KV PVC $NS/$SCALE_PVC; run prepare-scale-kv.sh first" >&2
    exit 2
  }
fi

doc="$(kubectl --context "$CONTEXT" -n "$NS" get deployment "$DEPLOY" -o json)"
ci="$(jq -r '.spec.template.spec.containers | to_entries[] | select(.value.name=="vllm") | .key' <<<"$doc")"
[ -n "$ci" ] || { echo "vllm container not found in deployment/$DEPLOY" >&2; exit 1; }

case "$MODE" in
  memory)
    kv_arg="--kv-transfer-config={\"kv_connector\":\"OffloadingConnector\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\":{\"spec_name\":\"TieringOffloadingSpec\",\"cpu_bytes_to_use\":$CPU_BYTES,\"secondary_tiers\":[]}}"
    volume='null'
    mount='null'
    ;;
  local)
    kv_arg="--kv-transfer-config={\"kv_connector\":\"OffloadingConnector\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\":{\"spec_name\":\"TieringOffloadingSpec\",\"cpu_bytes_to_use\":$CPU_BYTES,\"secondary_tiers\":[{\"type\":\"fs\",\"root_dir\":\"/mnt/kv-cache\",\"n_read_threads\":32,\"n_write_threads\":16,\"locality\":\"LOCAL\"}]}}"
    volume="$(jq -nc --arg path "$LOCAL_PATH" '{name:"kv-cache",hostPath:{path:$path,type:"Directory"}}')"
    mount='{"name":"kv-cache","mountPath":"/mnt/kv-cache"}'
    ;;
  scale)
    kv_arg="--kv-transfer-config={\"kv_connector\":\"OffloadingConnector\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\":{\"spec_name\":\"TieringOffloadingSpec\",\"cpu_bytes_to_use\":$CPU_BYTES,\"secondary_tiers\":[{\"type\":\"fs\",\"root_dir\":\"/mnt/kv-cache\",\"n_read_threads\":32,\"n_write_threads\":16,\"locality\":\"LOCAL\"}]}}"
    volume="$(jq -nc --arg claim "$SCALE_PVC" '{name:"kv-cache",persistentVolumeClaim:{claimName:$claim}}')"
    mount='{"name":"kv-cache","mountPath":"/mnt/kv-cache"}'
    ;;
esac

# Build the list replacements from the live object, preserving every unrelated chart field.
patch="$(jq -nc --argjson doc "$doc" --argjson ci "$ci" --arg mode "$MODE" --arg arg "$kv_arg" --argjson volume "$volume" --argjson mount "$mount" '
  ($doc.spec.template.spec.containers[$ci].args | map(select(startswith("--kv-transfer-config=")|not)) + [$arg]) as $args |
  ($doc.spec.template.spec.containers[$ci].volumeMounts // [] | map(select(.name != "kv-cache" and .name != "kv-cache-local")) + (if $mount == null then [] else [$mount] end)) as $mounts |
  ($doc.spec.template.spec.volumes // [] | map(select(.name != "kv-cache" and .name != "kv-cache-local")) + (if $volume == null then [] else [$volume] end)) as $volumes |
  [
    {op:"add",path:("/spec/template/spec/containers/"+($ci|tostring)+"/args"),value:$args},
    {op:"add",path:("/spec/template/spec/containers/"+($ci|tostring)+"/volumeMounts"),value:$mounts},
    {op:"add",path:"/spec/template/spec/volumes",value:$volumes}
  ]')"

echo "Switching Nemotron KV mode to $MODE; this restarts the model pod."
if [ "${DRY_RUN:-0}" = 1 ]; then
  kubectl --context "$CONTEXT" -n "$NS" patch deployment "$DEPLOY" \
    --type=json -p="$patch" --dry-run=server -o name
  echo "Dry run accepted; no changes applied."
  exit 0
fi
kubectl --context "$CONTEXT" -n "$NS" patch deployment "$DEPLOY" --type=json -p="$patch" >/dev/null
kubectl --context "$CONTEXT" -n "$NS" annotate deployment "$DEPLOY" \
  agentic-scale.rossoctl.io/kv-mode="$MODE" --overwrite >/dev/null
wait_for_current_pod
echo "KV mode active: $MODE"
