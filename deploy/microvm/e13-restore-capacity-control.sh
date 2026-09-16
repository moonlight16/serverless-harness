#!/usr/bin/env bash
# deploy/microvm/e13-restore-capacity-control.sh
#
# Follow-up to issue #271 / PR #272 (E12). PR #272's rung C@128 showed a
# ~40% connection-failure rate, and every observed failure is a
# guest_client-relay-level error talking to the EXISTING, already-shipped
# agent port (1024) - not the new port (1025) E12 added. This script isolates
# whether N=128 CONCURRENT RESTORES ALONE reproduce that failure rate, with
# the second-port mechanism removed entirely: no listener on 1025, no
# guest-side python script, nothing E12 introduced. If the same failure rate
# appears here, PR #272's finding is not about the new mechanism at all - it
# is a pre-existing concurrent-restore capacity limit on this rig that would
# also affect P4's already-shipped host-initiated Exec path.
#
# Reuses e12-vsock-egress-probe.sh's own lifecycle functions (preflight,
# assert_snapshot_pristine, restore_vm, wait_for_agent, teardown_jail,
# write_json_record, die/log) via its documented E12_PROBE_SOURCE_ONLY=1
# escape hatch - the same hook e12-vsock-egress-probe.test.sh already uses to
# test one function in isolation. This is not the "copy, don't share"
# situation build-snapshot.sh's own test creates: e12's driver has no
# statement-order-coupled test grepping these functions' bodies, so sourcing
# its already-modular functions carries none of that risk, and this script
# never edits e12-vsock-egress-probe.sh.
#
# Usage:
#   SH_SUBSTRATE=nested-m8i \
#   SH_GUEST_CLIENT=/path/to/guest_client \
#   SH_E13_N=128 \
#   sudo -E deploy/microvm/e13-restore-capacity-control.sh
set -uo pipefail

E12_PROBE_SOURCE_ONLY=1
export E12_PROBE_SOURCE_ONLY
# shellcheck source=e12-vsock-egress-probe.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e12-vsock-egress-probe.sh"

# Own results/jail dirs - never e12's (or e11's) - so a concurrent or later
# run of either cannot collide with this script's jails or overwrite its
# records.
RESULTS="${SH_E13_RESULTS:-/tmp/e13-control-results}"
JAIL_BASE="${SH_E13_JAIL_BASE:-/srv/e13-jails}"
N="${SH_E13_N:-128}"
mkdir -p "$RESULTS" "$JAIL_BASE" || die "could not create E13 results/jail dirs"

# run_control_n restores N VMs CONCURRENTLY - the same shape as e12's rung C -
# and, once each is up, runs ONLY the existing host-initiated Exec on port
# 1024: no listener on 1025, no guest-side probe script, no run_probe_once
# call anywhere in this file. A failure here can only be about restoring N
# VMs at once and then talking to the agent P4 already ships on; it cannot be
# about anything E12 added.
run_control_n() {
  local n="$1" i pids=()
  for i in $(seq 1 "$n"); do
    local jail="$JAIL_BASE/control-${n}-${i}"
    rm -rf "$jail"
    (
      local rc=0 exit_code=0
      restore_vm "$jail" 2>"$jail.boot.log" || {
        write_json_record "$RESULTS/control-${n}-${i}.json" \
          "{\"rung\":\"control-${n}-${i}\",\"ok\":false,\"error\":\"restore_vm failed\"}"
        exit 1
      }
      "$GUEST_CLIENT" -uds "$VM_UDS" -port "$AGENT_PORT" -timeout-s 15 -command true >/dev/null 2>&1 ||
        exit_code=$?
      [ "$exit_code" -eq 0 ] || rc=1
      write_json_record "$RESULTS/control-${n}-${i}.json" \
        "$(printf '{"rung":"control-%s-%s","ok":%s,"guest_client_exit":%s}' \
          "$n" "$i" "$([ "$exit_code" -eq 0 ] && echo true || echo false)" "$exit_code")"
      teardown_jail "$jail" "$CLEANUP_PID"
      exit "$rc"
    ) &
    pids+=("$!")
  done

  local ok_count=0 fail_count=0 pid
  for pid in "${pids[@]}"; do
    if wait "$pid"; then ok_count=$((ok_count + 1)); else fail_count=$((fail_count + 1)); fi
  done

  local all_ok=false
  [ "$fail_count" -eq 0 ] && all_ok=true
  write_json_record "$RESULTS/control-${n}.json" \
    "$(printf '{"rung":"control-%s","n":%s,"ok":%s,"ok_count":%s,"fail_count":%s}' \
      "$n" "$n" "$all_ok" "$ok_count" "$fail_count")"
  log "control(n=$n): ok_count=$ok_count fail_count=$fail_count all_ok=$all_ok"
  [ "$all_ok" = true ]
}

# Deliberately shadows e12-vsock-egress-probe.sh's own `main`, which the
# source above never invoked (E12_PROBE_SOURCE_ONLY=1) - bash resolves `main`
# to whichever definition executed most recently in this shell, and that is
# this one.
main() {
  preflight
  assert_snapshot_pristine "$SNAPSHOT_DIR" before
  local overall_ok=true
  run_control_n "$N" || overall_ok=false
  assert_snapshot_pristine "$SNAPSHOT_DIR" after
  write_json_record "$RESULTS/e13-control-answer.json" \
    "$(printf '{"substrate":%s,"n":%s,"ok":%s}' "$(json_escape "$SUBSTRATE")" "$N" "$overall_ok")"
  log "E13 CONTROL ANSWER: N=$N concurrent restores, existing 1024 Exec only -> ok=$overall_ok"
  [ "$overall_ok" = true ]
}

if [ "${E13_CONTROL_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
