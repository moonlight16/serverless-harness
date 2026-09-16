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

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "all checks passed"
