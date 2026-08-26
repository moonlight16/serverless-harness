#!/usr/bin/env bash
# deploy/knative/turn-stream-smoke.sh
# Gated live smoke for SSE streaming /turn (design §5.3, ADR-0029). Proves end-to-end that
# streaming ACTUALLY streams (inter-frame arrival timing, not just final content — the
# anti-buffering assertion from §4), and that a streamed session resumes like the sync path.
#
# Requires the streaming revision annotated
#   autoscaling.knative.dev/target-burst-capacity: "0"
# so the Knative activator drops out of the path (§4); without it the activator may buffer and
# batch all deltas to the end, failing the timing assertion loudly.
#
# Usage: TURN_STREAM_LIVE_SMOKE=1 bash deploy/knative/turn-stream-smoke.sh
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091  # lib.sh is co-located; not available to shellcheck at lint time
source ./lib.sh

# claim() is a script-local header helper in the smoke scripts (see leaf-async-smoke.sh),
# not a lib.sh export — define it here so the live path prints claim banners.
claim() { echo ""; echo "--- Claim $1: $2 ---"; }

[ "${TURN_STREAM_LIVE_SMOKE:-0}" = "1" ] || { echo "SKIP turn-stream-smoke (set TURN_STREAM_LIVE_SMOKE=1)"; exit 0; }

echo "=== Turn SSE streaming smoke ==="
ensure_port_forward >/dev/null || true

# Claim 1: a fresh streaming turn (no sessionId → executeTurn creates one) yields incremental text
# deltas and a terminal `done` carrying the new sessionId. /turn is createIfAbsent:false, so we do
# NOT pass a sessionId on the first turn — a fresh id would 404.
claim 1 "SSE deltas arrive incrementally + terminal done carries sessionId"
body=$(jq -nc --arg p "Count slowly from 1 to 5, one number per line, pausing briefly between each." '{prompt:$p}')
tmp=$(mktemp)
# -N disables curl output buffering. Stamp each line with epoch-ms so we can measure inter-frame gaps.
curl -sN --max-time 120 -H "$HOST_HEADER" -H "Content-Type: application/json" \
     -H "Accept: text/event-stream" -d "$body" "$BASE/turn" \
  | while IFS= read -r line; do printf '%s\t%s\n' "$(now_ms)" "$line"; done > "$tmp" || true

text_frames=$(grep -c $'\tevent: text$' "$tmp" || true)
if [ "${text_frames:-0}" -ge 1 ]; then ok "received $text_frames text delta frame(s)"; else ko "no text delta frames:\n$(cat "$tmp")"; fi

# terminal done frame: the data: line immediately after `event: done`. Strip the ms-stamp prefix.
done_data=$(grep -A1 $'\tevent: done$' "$tmp" | grep $'\tdata: ' | head -1 | sed 's/^[0-9]*\tdata: //' || true)
NEW_SID=$(printf '%s' "$done_data" | jq -r '.sessionId // empty' 2>/dev/null || echo "")
if [ -n "$NEW_SID" ]; then ok "terminal done carried sessionId=$NEW_SID"; else ko "no sessionId in done frame: $done_data"; fi

# Anti-buffering (§4): >=2 data frames, and the span from the first data frame to the terminal
# done is meaningfully > 0 — frames did NOT all land in the same instant (not buffered to the end).
first_ts=$(grep $'\tdata: ' "$tmp" | head -1 | cut -f1 || true)
last_ts=$(grep $'\tevent: done$' "$tmp" | head -1 | cut -f1 || true)
data_frames=$(grep -c $'\tdata: ' "$tmp" || true)
if [ "${data_frames:-0}" -ge 2 ] && [ -n "$first_ts" ] && [ -n "$last_ts" ] && [ "$((last_ts - first_ts))" -ge 50 ]; then
  ok "frames arrived incrementally over $((last_ts - first_ts))ms ($data_frames data frames)"
else
  ko "frames not incremental (span=$((last_ts - first_ts))ms, frames=${data_frames:-0}) — activator buffering?"
fi
rm -f "$tmp"

# Claim 2: resume parity — a follow-up streaming turn on the SAME sessionId resumes the session
# (proves the streamed session persisted identically to the sync path).
claim 2 "Resume parity: follow-up turn on the streamed sessionId"
if [ -z "$NEW_SID" ]; then
  ko "cannot test resume — no sessionId from claim 1"
else
  body2=$(jq -nc --arg s "$NEW_SID" --arg p "What was the last number you said?" '{sessionId:$s, prompt:$p}')
  resume_out=$(curl -sN --max-time 120 -H "$HOST_HEADER" -H "Content-Type: application/json" \
       -H "Accept: text/event-stream" -d "$body2" "$BASE/turn" || true)
  resume_done=$(printf '%s' "$resume_out" | grep -A1 '^event: done$' | grep '^data: ' | head -1 | sed 's/^data: //' || true)
  resume_sid=$(printf '%s' "$resume_done" | jq -r '.sessionId // empty' 2>/dev/null || echo "")
  if [ "$resume_sid" = "$NEW_SID" ]; then ok "resumed same session ($resume_sid)"; else ko "resume sessionId mismatch: got '$resume_sid' want '$NEW_SID'"; fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then echo "TURN STREAM SMOKE FAIL"; exit 1; else echo "TURN STREAM SMOKE PASS"; exit 0; fi
