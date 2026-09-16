#!/usr/bin/env bash
# deploy/microvm/tests/e12-vsock-egress-probe.test.sh
#
# Cluster-free, KVM-free tests for e12-vsock-egress-probe.sh. The driver itself
# needs /dev/kvm, a real Firecracker binary and a golden snapshot, so it cannot run
# on every PR -- but its CONTRACT can rot silently, and E12 answers a boolean that
# gates PR #268 entirely. A rotted contract here produces a boolean nobody should
# trust:
#
#   - it must refuse without SH_SUBSTRATE, and refuse a bare "nested" (E9 requires
#     the substrate be labeled by rig, not by class).
#   - it must be STRUCTURALLY incapable of printing STOP or MANDATORY: E12 has no
#     verdict, and a driver that can emit one invites a reader to treat a boolean
#     as a decision rule.
#   - it must verify the golden snapshot's rootfs digest BEFORE and AFTER a run.
#     A read-write mount alone changes an ext4 superblock, which would silently
#     invalidate #266's snapshot -- exit 0, no error, wrong result.
#   - it must die on an empty or unparseable per-rung record (#266's
#     mem_available_bytes bug: a missing rung still let a verdict print).
#   - it must require BOTH witnesses -- host-side nonce capture AND guest-side ACK
#     -- never either alone.
#
# The whole script cannot be sourced for these checks: it ends in an unconditional
# `main "$@"` that would immediately demand /dev/kvm and a snapshot. The driver
# supports E12_PROBE_SOURCE_ONLY=1 to skip main; for testing ONE function in
# isolation this file extracts that function's own source text and sources only
# that snippet in a subshell -- the same pattern e10-lifecycle.test.sh and
# build-snapshot.test.sh both use.
#
# Run: bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/e12-vsock-egress-probe.sh"
fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else
  echo "  FAIL: $1 (want '$3', got '$2')"
  fails=$((fails + 1))
fi; }

# extract_fn prints the source text of a top-level "name() { ... }" function
# (opening line "name() {" and closing bare "}") from $SCRIPT.
extract_fn() {
  local name="$1" start end
  start=$(grep -n "^${name}() {" "$SCRIPT" | head -n1 | cut -d: -f1)
  [ -n "$start" ] || return 1
  end=$(awk -v s="$start" 'NR>s && /^}$/{print NR; exit}' "$SCRIPT")
  [ -n "$end" ] || return 1
  sed -n "${start},${end}p" "$SCRIPT"
}

echo "== the script exists, is executable, and is shellcheck-clean"
check "driver present" "$([ -f "$SCRIPT" ] && echo yes || echo no)" "yes"
check "driver executable" "$([ -x "$SCRIPT" ] && echo yes || echo no)" "yes"
if command -v shellcheck >/dev/null; then
  if shellcheck "$SCRIPT" >/tmp/e12-shellcheck.out 2>&1; then
    check "shellcheck" "clean" "clean"
  else
    check "shellcheck" "$(cat /tmp/e12-shellcheck.out)" "clean"
  fi
else
  echo "  skip: shellcheck not installed"
fi

echo "== set -uo pipefail, and NOT set -e (both sibling drivers omit -e deliberately)"
check "has set -uo pipefail" \
  "$(grep -cE '^set -uo pipefail$' "$SCRIPT")" "1"
check "does not set -e" \
  "$(grep -cE '^set -e|^set -[a-z]*e[a-z]* ' "$SCRIPT")" "0"

echo "== die and log are defined before their first caller"
die_line=$(grep -n '^die() {' "$SCRIPT" | head -n1 | cut -d: -f1)
first_call=$(grep -nE '(^|[^_[:alnum:]])die ' "$SCRIPT" | grep -v '^[0-9]*:die() {' | head -n1 | cut -d: -f1)
check "die defined before first use" \
  "$([ -n "$die_line" ] && [ -n "$first_call" ] && [ "$die_line" -lt "$first_call" ] && echo yes || echo no)" "yes"

echo "== SH_SUBSTRATE is required, and a bare 'nested' is refused"
out=$(env -u SH_SUBSTRATE bash "$SCRIPT" 2>&1)
check "refuses with no SH_SUBSTRATE" \
  "$(echo "$out" | grep -c 'SH_SUBSTRATE')" "1"
out=$(SH_SUBSTRATE=nested bash "$SCRIPT" 2>&1)
check "refuses a bare 'nested'" \
  "$([ "$(echo "$out" | grep -ci 'rig')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== structurally incapable of a verdict: no STOP/MANDATORY anywhere in the source"
check "no STOP token" "$(grep -c '\bSTOP\b' "$SCRIPT")" "0"
check "no MANDATORY token" "$(grep -c '\bMANDATORY\b' "$SCRIPT")" "0"

echo "== the snapshot integrity guard runs before AND after, and reads the manifest"
pristine_body="$(extract_fn assert_snapshot_pristine || true)"
check "assert_snapshot_pristine exists" \
  "$([ -n "$pristine_body" ] && echo yes || echo no)" "yes"
check "it compares against manifest rootfs_sha256" \
  "$(echo "$pristine_body" | grep -c 'rootfs_sha256')" "2"
check "it dies on drift" \
  "$([ "$(echo "$pristine_body" | grep -c 'die')" -ge 1 ] && echo yes || echo no)" "yes"
check "called with a 'before' phase" \
  "$([ "$(grep -c 'assert_snapshot_pristine "\$SNAPSHOT_DIR" before' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "called with an 'after' phase" \
  "$([ "$(grep -c 'assert_snapshot_pristine "\$SNAPSHOT_DIR" after' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"

echo "== write_json_record dies on an empty or unparseable record (#266's bug class)"
rec_body="$(extract_fn write_json_record || true)"
check "write_json_record exists" "$([ -n "$rec_body" ] && echo yes || echo no)" "yes"
check "it rejects an empty record" \
  "$([ "$(echo "$rec_body" | grep -c '\-s ')" -ge 1 ] && echo yes || echo no)" "yes"
check "it validates JSON" \
  "$([ "$(echo "$rec_body" | grep -c 'json.load')" -ge 1 ] && echo yes || echo no)" "yes"

# Behavioural, not textual: call the real function on a real bad input.
rec_tmp="$(mktemp -d)"
( eval "die() { echo \"e12: \$*\" >&2; exit 1; }"$'\n'"$rec_body"
  write_json_record "$rec_tmp/empty.json" "" ) >/dev/null 2>&1
check "write_json_record exits non-zero on empty JSON text" "$?" "1"
( eval "die() { echo \"e12: \$*\" >&2; exit 1; }"$'\n'"$rec_body"
  write_json_record "$rec_tmp/bad.json" "{not json" ) >/dev/null 2>&1
check "write_json_record exits non-zero on malformed JSON" "$?" "1"
( eval "die() { echo \"e12: \$*\" >&2; exit 1; }"$'\n'"$rec_body"
  write_json_record "$rec_tmp/good.json" '{"rung":"A","ok":true}' ) >/dev/null 2>&1
check "write_json_record accepts valid JSON" "$?" "0"
rm -rf "$rec_tmp"

echo "== jail helpers exist and are named after what they copy"
for fn in api_put wait_for_socket prepare_jail link_snapshot_into_jail teardown_jail; do
  body="$(extract_fn "$fn" || true)"
  check "$fn exists" "$([ -n "$body" ] && echo yes || echo no)" "yes"
done

echo "== wait_for_socket polls with a real HTTP round trip, not a bare existence check"
wfs_body="$(extract_fn wait_for_socket || true)"
check "wait_for_socket uses curl, not just [ -S ]" \
  "$([ "$(echo "$wfs_body" | grep -c 'curl')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== link_snapshot_into_jail never opens the snapshot for writing"
link_body="$(extract_fn link_snapshot_into_jail || true)"
check "no O_WRONLY-shaped redirection into \$SNAPSHOT_DIR" \
  "$(echo "$link_body" | grep -cE '>\s*"?\$SNAPSHOT_DIR')" "0"
check "uses ln (hardlink), with a cp fallback" \
  "$([ "$(echo "$link_body" | grep -c '\bln\b')" -ge 1 ] && [ "$(echo "$link_body" | grep -c '\bcp\b')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== teardown_jail kills the VMM and does not leave the jail behind"
td_body="$(extract_fn teardown_jail || true)"
check "teardown_jail sends a kill" \
  "$([ "$(echo "$td_body" | grep -c '\bkill\b')" -ge 1 ] && echo yes || echo no)" "yes"
check "teardown_jail removes the jail dir" \
  "$([ "$(echo "$td_body" | grep -c 'rm -rf')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== the two-witness probe: host listener, guest command, and the combining check"
for fn in start_host_listener stop_host_listener guest_probe_command run_probe_once; do
  body="$(extract_fn "$fn" || true)"
  check "$fn exists" "$([ -n "$body" ] && echo yes || echo no)" "yes"
done

echo "== the guest probe connects to CID 2, not CID 3 (guest connects OUT to the host)"
check "guest_probe_command embeds the guest-side python3 script" \
  "$([ "$(grep -c 'AF_VSOCK' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "the embedded script targets VMADDR_CID_HOST (2), not the guest's own CID" \
  "$([ "$(grep -c 'VMADDR_CID_HOST' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"

echo "== run_probe_once requires BOTH witnesses, never either alone"
rpo_body="$(extract_fn run_probe_once || true)"
check "checks the host-side capture file" \
  "$([ "$(echo "$rpo_body" | grep -c 'capture')" -ge 1 ] && echo yes || echo no)" "yes"
check "checks the guest stdout for an ACK" \
  "$([ "$(echo "$rpo_body" | grep -c 'ACK')" -ge 1 ] && echo yes || echo no)" "yes"
# Both witness variables must appear together on the SAME line joined by &&,
# not merely somewhere in the function (which "true" for host_ok and later,
# separately, for guest_ok would also satisfy) and not joined by ||.
check "combines both with an explicit AND (&&), not an OR" \
  "$([ "$(echo "$rpo_body" | grep -cE '\$host_ok.*&&.*\$guest_ok|\$guest_ok.*&&.*\$host_ok')" -ge 1 ] && echo yes || echo no)" "yes"
check "does not combine the two witnesses with ||" \
  "$(echo "$rpo_body" | grep -cE '\$host_ok.*\|\||\$guest_ok.*\|\|')" "0"

echo "== the host listener behaves like a real accept-once-and-reply server"
listener_tmp="$(mktemp -d)"
start_body="$(extract_fn start_host_listener || true)"
stop_body="$(extract_fn stop_host_listener || true)"
(
  # start_host_listener references $PROBE_PORT, a global normally set when the
  # whole script is sourced - it must be set explicitly here since this
  # subshell only defines the one extracted function, not the driver's env
  # contract (Task 2). It is set to the same 1025 default the driver itself
  # uses, matching the hardcoded socket path this test connects to below.
  PROBE_PORT=1025
  eval "die() { echo \"e12: \$*\" >&2; exit 1; }"$'\n'"log() { :; }"$'\n'"$start_body"$'\n'"$stop_body"
  out="$(start_host_listener "$listener_tmp" testnonce123)"
  pid="${out#pid:}"; pid="${pid%% *}"
  sock="$listener_tmp/vsock.sock_1025"
  # Poll briefly for the listener to bind (it is backgrounded).
  for _ in $(seq 1 20); do [ -S "$sock" ] && break; sleep 0.1; done
  echo -n "testnonce123" | python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(sys.stdin.buffer.read() + b"\n")
print(s.recv(4096).decode().strip())
' "$sock" >"$listener_tmp/reply.txt" 2>&1
  stop_host_listener "$pid"
) >"$listener_tmp/out.log" 2>&1
check "listener replied with the expected ACK" \
  "$(cat "$listener_tmp/reply.txt" 2>/dev/null)" "ACK testnonce123"
check "listener captured the nonce to its capture file" \
  "$(cat "$listener_tmp/vsock.sock_1025.captured" 2>/dev/null)" "testnonce123"
rm -rf "$listener_tmp"

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "all checks passed"
