#!/usr/bin/env bash
# deploy/microvm/e13-mem-telemetry.sh
#
# Wraps an arbitrary command with host memory + OOM-killer telemetry, for the
# command's exact wall-clock duration. Exists to test E13's leading
# hypothesis for PR #272's rung C@128 failures: host memory exhaustion
# (issue #266's own E10/E11 nested-m8i run already found this rig's
# admission budget - ~288 MiB/resident VM against 15 GiB total - caps SAFE
# concurrency well under 128; PR #272 ran 128 with no admission gate at all).
#
# Does not touch e12-vsock-egress-probe.sh or e13-restore-capacity-control.sh
# - wraps either (or anything else) as an opaque command.
#
# Usage:
#   deploy/microvm/e13-mem-telemetry.sh <out-dir> -- <command> [args...]
set -uo pipefail

die() { echo "e13-mem-telemetry: $*" >&2; exit 1; }
log() { echo "e13-mem-telemetry: $*" >&2; }

[ "$#" -ge 3 ] || die "usage: e13-mem-telemetry.sh <out-dir> -- <command> [args...]"
OUT_DIR="$1"; shift
[ "$1" = "--" ] || die "expected '--' before the wrapped command, got '$1'"
shift

mkdir -p "$OUT_DIR" || die "could not create $OUT_DIR"
MEM_LOG="$OUT_DIR/mem-timeline.log"
OOM_LOG="$OUT_DIR/oom-events.log"
META="$OUT_DIR/telemetry-meta.json"
: >"$MEM_LOG"
: >"$OOM_LOG"

# Sampled from /proc/meminfo directly, matching E10/E11's own MemAvailable
# convention (EXPERIMENTS.md's mem_available_bytes) rather than parsing
# `free`'s locale-dependent text - one line per sample, epoch seconds then
# MemAvailable in bytes.
python3 -c '
import time, sys
outfile = sys.argv[1]
with open(outfile, "a") as f:
    while True:
        avail = None
        with open("/proc/meminfo") as m:
            for line in m:
                if line.startswith("MemAvailable:"):
                    avail = int(line.split()[1]) * 1024
                    break
        f.write(f"{time.time():.3f} {avail if avail is not None else -1}\n")
        f.flush()
        time.sleep(1)
' "$MEM_LOG" &
MEM_PID=$!

# journalctl -o short-unix gives an epoch-seconds prefix on every line, so
# e13-correlate.py needs no log-format-specific date parsing. Falls back to
# `dmesg -T -w` only if journalctl is unavailable - recorded in
# telemetry-meta.json's oom_watcher field either way, so a quiet
# oom-events.log is never mistaken for "no watcher running".
# Process substitution (`> >(grep ...)`), not a pipeline (`cmd | grep ...`),
# so that `$!` captures the watcher's own PID rather than grep's - `$!`
# after a backgrounded pipeline always names the LAST command in it. With
# process substitution, killing the watcher closes its stdout, grep sees
# EOF on its stdin and exits on its own; no need to track or kill grep too.
OOM_WATCHER=journalctl
if command -v journalctl >/dev/null 2>&1; then
  journalctl -kf --no-pager -o short-unix > >(grep --line-buffered -iE 'killed process|out of memory|oom-kill|oom_kill' >"$OOM_LOG") 2>/dev/null &
  OOM_PID=$!
else
  OOM_WATCHER=dmesg
  dmesg -T -w > >(grep --line-buffered -iE 'killed process|out of memory|oom-kill|oom_kill' >"$OOM_LOG") 2>/dev/null &
  OOM_PID=$!
fi

# Armed before the liveness checks below so that even the immediate-death
# path (e.g. die() on a missing /proc/meminfo) cleans up the watcher instead
# of leaking it.
cleanup() {
  kill "$MEM_PID" "$OOM_PID" 2>/dev/null || true
  wait "$MEM_PID" "$OOM_PID" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1
kill -0 "$MEM_PID" 2>/dev/null || die "mem sampler died immediately - check python3/proc/meminfo access"
OOM_ALIVE=false
kill -0 "$OOM_PID" 2>/dev/null && OOM_ALIVE=true

START=$(python3 -c 'import time; print(f"{time.time():.3f}")')
log "starting: $* (telemetry: $OUT_DIR, oom_watcher=$OOM_WATCHER, oom_watcher_alive=$OOM_ALIVE)"
RC=0
"$@" || RC=$?
END=$(python3 -c 'import time; print(f"{time.time():.3f}")')

python3 -c '
import json, sys
json.dump(
    {
        "start": float(sys.argv[1]),
        "end": float(sys.argv[2]),
        "wrapped_exit": int(sys.argv[3]),
        "oom_watcher": sys.argv[4],
        "oom_watcher_alive_at_start": sys.argv[5] == "true",
    },
    open(sys.argv[6], "w"),
)
' "$START" "$END" "$RC" "$OOM_WATCHER" "$OOM_ALIVE" "$META"

log "wrapped command exited $RC; telemetry meta written to $META"
exit "$RC"
