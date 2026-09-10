#!/usr/bin/env bash
# Sends repeated identical prompts and prints vLLM cache metrics before/after each request.
set -euo pipefail

CONTEXT="${CONTEXT:-agentic-cloud}"
NS="${NS:-llm-d}"
URL="${URL:-https://llm.163-75-85-180.sslip.io/nemotron-3-ultra/v1/messages}"
MODEL="${MODEL:-nvidia/nemotron-3-ultra}"
REPEATS="${REPEATS:-2}"
PREFIX_WORDS="${PREFIX_WORDS:-6000}"
POD="$(kubectl --context "$CONTEXT" -n "$NS" get pod \
  -l 'cs.io/llm-d-release=nvidia-nemotron-3-ultra,llm-d.ai/role=decode' \
  -o jsonpath='{.items[0].metadata.name}')"
API_KEY="$(kubectl --context "$CONTEXT" -n "$NS" get secret llm-d-api-key \
  -o jsonpath='{.data.api-key}' | base64 -d)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk -v n="$PREFIX_WORDS" 'BEGIN {
  for (i=0; i<n; i++) printf "repository-context-%d ", i%200;
  print "\nQuestion: Return only the word READY.";
}' >"$TMP/prompt.txt"

jq -n --rawfile prompt "$TMP/prompt.txt" --arg model "$MODEL" \
  '{model:$model,max_tokens:32,stream:true,messages:[{role:"user",content:$prompt}]}' \
  >"$TMP/request.json"

snapshot() {
  local label="$1"
  echo "--- metrics: $label"
  kubectl --context "$CONTEXT" -n "$NS" exec "$POD" -c vllm -- /usr/bin/python3 -c \
    'import re,urllib.request
s=urllib.request.urlopen("http://127.0.0.1:8000/metrics").read().decode()
for line in s.splitlines():
  if not line.startswith("#") and re.search(r"prefix_cache_(queries|hits)_total|external_prefix_cache_(queries|hits)_total|prompt_tokens_by_source_total|kv_offload_",line): print(line)'
}

snapshot before
for i in $(seq 1 "$REPEATS"); do
  curl -sSN -o "$TMP/response-$i.txt" \
    -w "request=$i status=%{http_code} first_byte=%{time_starttransfer}s total=%{time_total}s\n" \
    "$URL" \
    -H "x-api-key: $API_KEY" \
    -H "Authorization: Bearer $API_KEY" \
    -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    --data-binary "@$TMP/request.json"
  snapshot "after-$i"
done
