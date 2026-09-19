#!/usr/bin/env bash
# deploy/microvm/tests/e13-correlate.test.sh
#
# Fixture-based unit test for e13-correlate.py's hypothesis-testing logic -
# no VM, no root, no KVM. Builds 4 fake per-VM records (2 "failed" near a
# memory dip and an OOM event, 2 "ok" nowhere near either) and asserts the
# correlation counts land exactly where they should.
#
# Run: bash deploy/microvm/tests/e13-correlate.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/e13-correlate.py"
fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else
  echo "  FAIL: $1 (want '$3', got '$2')"
  fails=$((fails + 1))
fi; }

check "correlate.py present" "$([ -f "$SCRIPT" ] && echo yes || echo no)" "yes"
python3 -m py_compile "$SCRIPT" 2>/tmp/e13-correlate-pycompile.out
check "python3 -m py_compile" "$([ -s /tmp/e13-correlate-pycompile.out ] && echo FAIL || echo clean)" "clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results"
JAILS="$TMP/jails"
mkdir -p "$RESULTS" "$JAILS"

# mtime is set via python3's os.utime, not `touch -d "@<epoch>"` - that flag
# is GNU-only (BSD/macOS touch has no -d at all), and this test must pass on
# a contributor's Mac as readily as on the Linux rig or CI.
write_record() {
  local path="$1" ok="$2" mtime="$3"
  printf '{"rung":"x","ok":%s}' "$ok" > "$path"
  python3 -c "import os, sys; t = float(sys.argv[2]); os.utime(sys.argv[1], (t, t))" "$path" "$mtime"
}
write_record "$RESULTS/vm1.json" false 100
write_record "$RESULTS/vm2.json" false 101
write_record "$RESULTS/vm3.json" true 200
write_record "$RESULTS/vm4.json" true 201

MEM="$TMP/mem-timeline.log"
printf '99.0 104857600\n100.0 94371840\n101.0 83886080\n199.0 8589934592\n200.0 8589934592\n201.0 8589934592\n' > "$MEM"

OOM="$TMP/oom-events.log"
printf '100.4 host kernel: Out of memory: Killed process 1234 (firecracker)\n' > "$OOM"

OUT="$TMP/summary.json"
python3 "$SCRIPT" --results-glob "$RESULTS/*.json" --boot-log-glob "$JAILS/*.boot.log" \
  --mem-timeline "$MEM" --oom-events "$OOM" --out "$OUT" >/dev/null

check "total events" "$(python3 -c "import json; print(json.load(open('$OUT'))['total_events'])")" "4"
check "failed count" "$(python3 -c "import json; print(json.load(open('$OUT'))['failed_count'])")" "2"
check "both failures near the OOM event" \
  "$(python3 -c "import json; print(json.load(open('$OUT'))['failed_near_oom_event'])")" "2"
check "neither success near the OOM event" \
  "$(python3 -c "import json; print(json.load(open('$OUT'))['ok_near_oom_event'])")" "0"
check "both failures below the low-water mark" \
  "$(python3 -c "import json; print(json.load(open('$OUT'))['failed_below_low_water'])")" "2"
check "neither success below the low-water mark" \
  "$(python3 -c "import json; print(json.load(open('$OUT'))['ok_below_low_water'])")" "0"
check "all 6 mem samples parsed" \
  "$(python3 -c "import json; print(json.load(open('$OUT'))['mem_samples_total'])")" "6"
check "well-formed timeline reports no torn final line" \
  "$(python3 -c "import json; print(json.load(open('$OUT'))['mem_timeline_torn_final_line'])")" "False"

# A malformed line that is NOT a torn final line means the file is not what
# the caller says it is: refuse with the position, never skip the sample. A
# silently dropped sample here would understate memory pressure in exactly
# the direction that makes the memory hypothesis look falsified.
BAD_MEM="$TMP/mem-malformed.log"
printf '99.0 104857600\n100.0\n101.0 83886080\n' > "$BAD_MEM"
BAD_ERR="$TMP/mem-malformed.err"
python3 "$SCRIPT" --results-glob "$RESULTS/*.json" --boot-log-glob "$JAILS/*.boot.log" \
  --mem-timeline "$BAD_MEM" --oom-events "$OOM" --out "$TMP/bad.json" >/dev/null 2>"$BAD_ERR"
check "malformed interior line exits nonzero" "$?" "1"
check "refusal names the line number" \
  "$(grep -c 'mem-malformed.log:2: expected .epoch bytes.' "$BAD_ERR")" "1"
check "refusal writes no summary" "$([ -f "$TMP/bad.json" ] && echo yes || echo no)" "no"

# A torn final line (no trailing newline) is what a sampler killed mid-write
# actually leaves. Tolerated, because every preceding sample is still sound -
# but recorded in the summary and announced, never absorbed silently.
#
# The fixture's torn line is deliberately one that PARSES: "101.0 8" is a
# well-formed line carrying a truncated integer, and accepting it would inject
# a fake 8-byte MemAvailable reading - manufacturing the very memory pressure
# this script tests for. The missing newline is what disqualifies it.
TORN_MEM="$TMP/mem-torn.log"
printf '99.0 104857600\n100.0 94371840\n101.0 8' > "$TORN_MEM"
TORN_ERR="$TMP/mem-torn.err"
TORN_OUT="$TMP/torn.json"
python3 "$SCRIPT" --results-glob "$RESULTS/*.json" --boot-log-glob "$JAILS/*.boot.log" \
  --mem-timeline "$TORN_MEM" --oom-events "$OOM" --out "$TORN_OUT" >/dev/null 2>"$TORN_ERR"
check "torn final line exits zero" "$?" "0"
check "torn final line is recorded in the summary" \
  "$(python3 -c "import json; print(json.load(open('$TORN_OUT'))['mem_timeline_torn_final_line'])")" "True"
check "the 2 complete samples are kept" \
  "$(python3 -c "import json; print(json.load(open('$TORN_OUT'))['mem_samples_total'])")" "2"
check "discarded final line is announced on stderr" \
  "$(grep -c 'discarding unterminated final line' "$TORN_ERR")" "1"

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "all checks passed"
