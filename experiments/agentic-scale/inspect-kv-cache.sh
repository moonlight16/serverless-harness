#!/usr/bin/env bash
# Read-only inspection: reports filesystem KV-cache size and file count.
# It does not send inference requests or prove that cached KV blocks were reused.
set -euo pipefail

CONTEXT="${CONTEXT:-agentic-cloud}"
NS="${NS:-llm-d}"
RELEASE="${RELEASE:-nvidia-nemotron-3-ultra}"

POD="$(kubectl --context "$CONTEXT" -n "$NS" get pod \
  -l "cs.io/llm-d-release=$RELEASE,llm-d.ai/role=decode" \
  -o jsonpath='{.items[0].metadata.name}')"

[ -n "$POD" ] || { echo "No decode pod found for $RELEASE" >&2; exit 1; }
echo "Pod: $POD"
kubectl --context "$CONTEXT" -n "$NS" exec "$POD" -c vllm -- sh -c \
  'printf "Cache size: "; du -sh /mnt/kv-cache | cut -f1; printf "Cache files: "; find /mnt/kv-cache -type f | wc -l'
