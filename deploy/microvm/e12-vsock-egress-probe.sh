#!/usr/bin/env bash
# deploy/microvm/e12-vsock-egress-probe.sh
#
# E12 (issue #271): does a guest-initiated vsock connection on a SECOND port
# survive Firecracker snapshot restore, and survive N concurrent restores of one
# snapshot?
#
# This is a mechanism-existence probe, not a measurement. There is no threshold,
# no baseline and no ladder analysis: it prints a boolean. It gates PR #268's
# P4.1 egress transport, whose decision T1 routes all sandbox egress over vsock
# because the microVM tier has no network device at all.
#
# WHAT IS ALREADY KNOWN, and therefore not re-derived here:
#   - LISTENING vsock sockets survive restore with the CID updated, and
#     established connections are closed on resume. That is P4 §2.4, and it is
#     the HOST-INITIATED direction only.
#   - Guest->host is a different mechanism: the host must pre-create and listen
#     on <uds_path>_<PORT>, there is NO handshake, and Firecracker forwards the
#     connection when it sees VIRTIO_VSOCK_OP_REQUEST. The guest connects to
#     CID 2. If nobody listens, the guest gets VIRTIO_VSOCK_OP_RST.
#   - Firecracker's own docs say "vsock snapshot support is currently limited"
#     and note a device-reset limitation. That sentence is the entire reason
#     this script exists.
#
# WHY THERE IS NO SUBSTRATE BLACKLIST. Issue #271 says to run this on
# nested-m8i and "never metal", because folding a probe helper into a rootfs
# would change its digest and silently invalidate #266's metal comparison. That
# hazard is real but it is not about the substrate's NAME -- it is about writing
# to the snapshot. This driver never writes to it: it hardlinks the files in,
# mounts rootfs is_read_only, boots with `ro`, and verifies rootfs_sha256
# against manifest.json before AND after every run. That guard is mechanical and
# unconditional, so it also holds on the metal confirmation run the issue defers
# ("Metal confirmation should ride along with whichever later run builds a metal
# snapshot anyway"), which a name check would have had to be edited to allow.
#
# WHY IT DUPLICATES build-snapshot.sh's JAIL HELPERS instead of sharing them.
# deploy/microvm/tests/build-snapshot.test.sh greps write_guest_client's body and
# asserts statement ORDERING inside it. Extracting shared helpers out of a
# 1928-line, source-order-coupled script for a throwaway probe would break that
# test to no benefit. Each copied helper below names its origin.
#
# Usage:
#   SH_SUBSTRATE=nested-m8i \
#   SH_GUEST_CLIENT=/path/to/guest_client \
#   sudo -E deploy/microvm/e12-vsock-egress-probe.sh
#
set -uo pipefail

# Defined first, deliberately: e10-lifecycle.sh:128 records what happens
# otherwise -- "die: command not found" on the failure path, and the script
# carries on past the thing it was supposed to refuse.
die() { echo "e12: $*" >&2; exit 1; }
log() { echo "e12: $*" >&2; }

# SH_SUBSTRATE stays an explicit, required, operator-set env var rather than
# being sniffed: E9's own phrasing is that the rig must be named, not its class,
# because "nested" alone cannot tell two rigs apart in a run record.
SUBSTRATE="${SH_SUBSTRATE:?set SH_SUBSTRATE (e.g. nested-m8i or metal) - every run record must name the substrate, and E9 requires it be labeled by rig, not bare nested}"
case "$SUBSTRATE" in
  nested | nested- | metal-)
    die "SH_SUBSTRATE='$SUBSTRATE' is not rig-labeled - use a specific rig (e.g. nested-m8i), because a bare class cannot tell two rigs apart in a run record"
    ;;
esac

SNAPSHOT_DIR="${SH_SNAPSHOT_IMAGE_DIR:-/srv/snapshots/default}"
RESULTS="${SH_E12_RESULTS:-/tmp/e12-results}"
GUEST_CLIENT="${SH_GUEST_CLIENT:-}"
FIRECRACKER_BIN="${SH_FIRECRACKER_BIN:-firecracker}"
JAIL_BASE="${SH_E12_JAIL_BASE:-/srv/e12-jails}"
# shellcheck disable=SC2034 # consumed by Tasks 3-8 (the vsock probe port itself)
PROBE_PORT="${SH_E12_PROBE_PORT:-1025}"
AGENT_PORT=1024
# shellcheck disable=SC2034 # consumed by Tasks 3-8 (guest machine-config RAM)
GUEST_RAM_MB=256
# shellcheck disable=SC2034 # consumed by Tasks 3-8 (guest machine-config CID)
GUEST_CID=3
RUNGS="${SH_E12_RUNGS:-A B C D}"
# shellcheck disable=SC2034 # consumed by Tasks 3-8 (concurrent-restore ladder)
C_LADDER="${SH_E12_C_LADDER:-8 128}"

wants_rung() { case " $RUNGS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- snapshot integrity ------------------------------------------------------
# The golden snapshot is shared, read-only state. A read-write loop mount alone
# is enough to change an ext4 superblock, and that would invalidate #266's
# comparison INVISIBLY -- exit 0, no error, wrong result. So the digest is
# checked before and after, and a drift is fatal rather than a warning.
manifest_field() {
  local dir="$1" key="$2"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$dir/manifest.json" "$key"
}

snapshot_rootfs_digest() {
  local dir="$1"
  printf 'sha256:%s\n' "$(sha256sum "$dir/rootfs" | awk '{print $1}')"
}

assert_snapshot_pristine() {
  local dir="$1" phase="$2" want actual
  want="$(manifest_field "$dir" rootfs_sha256)" ||
    die "could not read rootfs_sha256 from $dir/manifest.json ($phase)"
  actual="$(snapshot_rootfs_digest "$dir")" ||
    die "could not digest $dir/rootfs ($phase)"
  [ "$actual" = "$want" ] ||
    die "golden snapshot rootfs digest drifted $phase the run: manifest says $want, the file is $actual. Something wrote to a snapshot that must stay read-only; do NOT trust any result from this run, and do not reuse this snapshot until it is rebuilt."
  log "snapshot rootfs digest verified $phase the run ($actual)"
}

# --- records -----------------------------------------------------------------
json_escape() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.argv[1]))' "$1"
}

# write_json_record refuses to leave behind a rung record that is empty or not
# parseable. #266 shipped a ladder whose mem_available_bytes was blank: the run
# exited 0 and still printed a verdict, and the missing field read as the most
# favourable value. A boolean probe has the same failure mode in a smaller
# space, so the guard is the same.
write_json_record() {
  local path="$1" body="$2"
  [ -n "$body" ] ||
    die "refusing to write an EMPTY record to $path - a rung that recorded nothing must not look like a rung that passed"
  printf '%s\n' "$body" >"$path" ||
    die "could not write the record for $path"
  [ -s "$path" ] ||
    die "the record at $path is zero bytes after writing"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$path" >/dev/null 2>&1 ||
    die "the record at $path is not valid JSON - refusing to read a boolean out of it"
}

# --- preflight ---------------------------------------------------------------
require_tool() {
  command -v "$1" >/dev/null 2>&1 ||
    die "required tool '$1' is not on PATH"
}

preflight() {
  [ "$(id -u)" -eq 0 ] ||
    die "must run as root: this script chroots, bind-mounts /dev/kvm and hardlinks into a jail"
  local t
  for t in curl python3 sha256sum awk mkfs.ext4 truncate; do require_tool "$t"; done
  command -v "$FIRECRACKER_BIN" >/dev/null 2>&1 ||
    die "firecracker binary '$FIRECRACKER_BIN' is not on PATH (override with SH_FIRECRACKER_BIN)"
  [ -c /dev/kvm ] || die "/dev/kvm is missing - this probe needs a hypervisor, there is no fake mode"
  [ -r /dev/kvm ] || die "/dev/kvm is not readable by root - check the kvm group and the device mode"
  [ -n "$GUEST_CLIENT" ] ||
    die "set SH_GUEST_CLIENT to a guest_client binary built from remote-worker (it speaks the framed protocol the guest agent listens for on vsock:$AGENT_PORT)"
  [ -x "$GUEST_CLIENT" ] || die "SH_GUEST_CLIENT='$GUEST_CLIENT' is not executable"
  [ -d "$SNAPSHOT_DIR" ] ||
    die "no golden snapshot at $SNAPSHOT_DIR (override with SH_SNAPSHOT_IMAGE_DIR); build one with deploy/microvm/build-snapshot.sh"
  local f
  for f in kernel rootfs memfile vmstate manifest.json; do
    [ -f "$SNAPSHOT_DIR/$f" ] ||
      die "the snapshot at $SNAPSHOT_DIR is missing $f"
  done
  python3 -c 'import socket,sys; sys.exit(0 if hasattr(socket,"AF_VSOCK") else 1)' ||
    die "this host's python3 has no AF_VSOCK - the host-side listener needs it"
  mkdir -p "$RESULTS" || die "could not create the results directory $RESULTS"
  mkdir -p "$JAIL_BASE" || die "could not create the jail base $JAIL_BASE"
  log "preflight ok: substrate=$SUBSTRATE snapshot=$SNAPSHOT_DIR results=$RESULTS"
}

# --- jail lifecycle -----------------------------------------------------------
# Copied from deploy/microvm/build-snapshot.sh's api_put / wait_for_socket /
# prepare_jail / teardown_jail rather than shared: build-snapshot.test.sh greps
# write_guest_client's body for statement ORDERING, and extracting a shared lib
# out of that 1928-line source-order-coupled script for a throwaway probe would
# break that test for no benefit to either script. Behavior here matches the
# original; only the vsock/probe pieces are new (Task 4 onward).

api_put() {
  local sock="$1" path="$2" body="$3"
  curl -s -S --unix-socket "$sock" -X PUT "http://localhost$path" \
    -H 'Content-Type: application/json' -d "$body" >/dev/null
}

# Matches build-snapshot.sh's own wait_for_socket: a bare `[ -e "$sock" ]` races,
# because Firecracker creates the socket file before it is actually accept()ing
# on it (confirmed on this rig: cloud-hypervisor lost that exact race). Poll with
# a real HTTP round trip instead; any response, even a 404, proves the daemon is
# accepting connections, which is the only thing this loop needs to prove.
wait_for_socket() {
  local sock="$1" console_log="$2" timeout_s="${3:-5}"
  local attempts=$((timeout_s * 10)) i=0
  while [ "$i" -lt "$attempts" ]; do
    if curl -s -S --unix-socket "$sock" -o /dev/null "http://localhost/" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  log "console log for the timed-out socket $sock:"
  cat "$console_log" >&2 2>/dev/null || true
  die "timed out after ${timeout_s}s waiting for $sock to accept connections"
}

CLEANUP_JAIL=""
CLEANUP_PID=""

jail_mount_dev() {
  local jail="$1"
  mkdir -p "$jail/dev"
  : >"$jail/dev/kvm"
  mount --bind /dev/kvm "$jail/dev/kvm" ||
    die "could not bind-mount /dev/kvm into the jail at $jail"
  : >"$jail/dev/urandom" 2>/dev/null || true
  mount --bind /dev/urandom "$jail/dev/urandom" 2>/dev/null || true
}

jail_unmount_dev() {
  local jail="$1"
  umount "$jail/dev/urandom" 2>/dev/null || true
  umount "$jail/dev/kvm" 2>/dev/null || true
}

prepare_jail() {
  local jail="$1"
  mkdir -p "$jail/run" || die "could not create $jail/run"
  # Always hardlinked in under the FIXED jail-relative name "firecracker",
  # regardless of what $FIRECRACKER_BIN resolves to on the host (e.g.
  # SH_FIRECRACKER_BIN=/opt/fc-1.17/firecracker-x86_64) - every caller below
  # execs "chroot \"$jail\" /firecracker", and that path must never depend on
  # the source binary's own basename. Matches build-snapshot.sh's
  # prepare_jail, which takes the jail-relative name as an explicit argument
  # for exactly this reason (its two arms hardlink to "firecracker" and
  # "cloud-hypervisor" respectively, never to the source path's basename).
  ln "$(command -v "$FIRECRACKER_BIN")" "$jail/firecracker" 2>/dev/null ||
    cp -p "$(command -v "$FIRECRACKER_BIN")" "$jail/firecracker"
  CLEANUP_JAIL="$jail"
  jail_mount_dev "$jail"
}

# link_snapshot_into_jail hardlinks the golden snapshot's four files into the
# jail. Hardlinking (not copying) is what keeps this cheap AND what keeps the
# guard in assert_snapshot_pristine meaningful -- a hardlink cannot be opened for
# writing by this process without ALSO changing the file every other hardlink
# (including the one under $SNAPSHOT_DIR) points at, which is exactly the drift
# assert_snapshot_pristine is watching for.
link_snapshot_into_jail() {
  local jail="$1" f
  for f in kernel rootfs memfile vmstate; do
    if ! ln "$SNAPSHOT_DIR/$f" "$jail/$f" 2>/dev/null; then
      log "WARNING: cross-device or no hardlink support - COPYING $f into $jail (last resort, not the normal path)"
      cp -p "$SNAPSHOT_DIR/$f" "$jail/$f"
    fi
  done
}

teardown_jail() {
  local jail="$1" pid="$2"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  jail_unmount_dev "$jail"
  rm -rf "$jail"
  CLEANUP_JAIL=""
  CLEANUP_PID=""
}

cleanup_on_exit() {
  if [ -n "$CLEANUP_PID" ]; then
    kill "$CLEANUP_PID" 2>/dev/null || true
  fi
  if [ -n "$CLEANUP_JAIL" ]; then
    jail_unmount_dev "$CLEANUP_JAIL"
    rm -rf "$CLEANUP_JAIL" 2>/dev/null || true
  fi
}
trap cleanup_on_exit EXIT

# --- the two-witness vsock probe ---------------------------------------------
# The question this whole script exists to answer has exactly one honest
# failure mode worth guarding against: believing a connection happened when it
# did not, or vice versa. So every check requires TWO INDEPENDENT witnesses:
#   1. HOST-SIDE (authoritative): the accept loop on <jail>/vsock.sock_1025
#      actually received the guest's nonce and wrote it to a capture file.
#   2. GUEST-SIDE (corroboration only, never a timing source - spec §2.4: guest
#      clocks jump on resume): the guest's own stdout, relayed back through the
#      EXISTING agent Exec path on vsock:1024, shows the ACK it read back.
# A witness that could be satisfied by either side alone is not verifying a
# vsock connection; it is verifying that a process ran, which is a strictly
# weaker claim than "the guest reached the host over the SECOND port".

# start_host_listener backs a single-shot accept loop with python3 (present on
# every host this driver's preflight already required). It listens on
# <jail>/vsock.sock_1025 -- the "<uds_path>_<PORT>" naming vsock.md documents
# for the guest-initiated direction -- accepts exactly one connection, reads one
# line, writes it verbatim to <jail>/vsock.sock_1025.captured, replies
# "ACK <line>\n", and exits. Firecracker needs no handshake for this direction:
# the socket only needs to EXIST at connect time.
start_host_listener() {
  # jail/nonce and sock are split into two `local` statements deliberately: a
  # single `local a="$1" b="$a/x"` does NOT let b see the freshly-assigned a -
  # bash expands every word of a command (local included) before the command
  # runs, so "$a" in b's assignment would resolve against whatever a held in
  # the ENCLOSING scope, not the value just set moments earlier in the same
  # statement. Under this script's `set -u`, that reads as an unbound
  # variable rather than merely a wrong value.
  local jail="$1" nonce="$2" pyfile
  local sock="$jail/vsock.sock_${PROBE_PORT}"
  pyfile="$jail/.e12-listener.py"
  cat >"$pyfile" <<'PYEOF'
import socket, sys, os
sock_path, capture_path = sys.argv[1], sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
os.chmod(sock_path, 0o666)
srv.listen(1)
conn, _ = srv.accept()
data = conn.recv(4096)
line = data.decode(errors="replace").strip()
with open(capture_path, "w") as f:
    f.write(line)
conn.sendall(("ACK " + line + "\n").encode())
conn.close()
srv.close()
PYEOF
  # Redirected, not left to inherit this function's own stdout/stderr: every
  # caller captures start_host_listener's return value via `out="$(...)"`,
  # and command substitution does not return until every holder of the
  # pipe's write end closes it - an unredirected backgrounded child inherits
  # that write end and keeps it open while blocked in accept(), which hangs
  # the whole capture forever whenever no client connects in time. Found the
  # hard way: this masked itself behind an unrelated bug in an earlier round
  # of this same task, and only surfaced once that bug was fixed.
  python3 "$pyfile" "$sock" "$sock.captured" >/dev/null 2>&1 &
  local pid=$!
  echo "pid:$pid capture:$sock.captured"
}

stop_host_listener() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# guest_probe_command returns a full shell command line for `guest_client
# -command`: it writes the embedded guest-side python3 script into the guest's
# /tmp via a base64 pipe (the agent runs `sh -c "$req.Command"`, so a pipeline is
# legal - remote-worker/internal/guestagent/agent.go:424), then runs it. The
# script connects AF_VSOCK to VMADDR_CID_HOST (2) -- the host, from the guest's
# point of view, per vsock.md -- on $PROBE_PORT, sends "E12 <nonce>", reads the
# reply, and prints it to guest stdout so guest_client relays it back to us.
guest_probe_command() {
  local nonce="$1" b64
  b64="$(cat <<'PYEOF' | base64 | tr -d '\n'
import socket, sys
nonce, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.settimeout(10)
s.connect((socket.VMADDR_CID_HOST, port))
s.sendall(("E12 " + nonce + "\n").encode())
reply = s.recv(4096).decode(errors="replace").strip()
print(reply)
s.close()
PYEOF
)"
  printf 'echo %s | base64 -d > /tmp/e12-probe.py && python3 /tmp/e12-probe.py %s %s' \
    "$b64" "$nonce" "$PROBE_PORT"
}

# run_probe_once is the single-VM check every rung reuses. It assumes the VM at
# $vsock_uds is already up (fresh-booted or restored) and its agent is already
# reachable on $AGENT_PORT - callers run wait_for_agent (Task 5/6/7) first.
#
# label names the record file this writes: $RESULTS/$label.json. The record's
# "ok" field is the boolean this whole probe exists to produce, and it is TRUE
# only when BOTH witnesses agree - never from either alone.
run_probe_once() {
  local jail="$1" vsock_uds="$2" label="$3"
  local nonce="e12-${label}-$$-${RANDOM}"
  local listener_out capture_path lpid
  listener_out="$(start_host_listener "$jail" "$nonce")"
  lpid="${listener_out#pid:}"; lpid="${lpid%% capture:*}"
  capture_path="${listener_out#*capture:}"

  local guest_out guest_rc=0
  guest_out="$("$GUEST_CLIENT" -uds "$vsock_uds" -port "$AGENT_PORT" -timeout-s 15 \
    -command "$(guest_probe_command "$nonce")" 2>&1)" || guest_rc=$?

  # Give the listener a moment to flush its capture file even if the guest side
  # already returned - the host accept()/recv()/write() can trail the guest's
  # own print by a few milliseconds.
  local i host_nonce=""
  for i in $(seq 1 20); do
    [ -f "$capture_path" ] && host_nonce="$(cat "$capture_path" 2>/dev/null)" && [ -n "$host_nonce" ] && break
    sleep 0.1
  done
  stop_host_listener "$lpid"

  local host_ok=no guest_ok=no
  [ "$host_nonce" = "$nonce" ] && host_ok=yes
  case "$guest_out" in *"ACK $nonce"*) guest_ok=yes ;; esac

  local ok=false
  [ "$host_ok" = yes ] && [ "$guest_ok" = yes ] && ok=true

  write_json_record "$RESULTS/${label}.json" "$(printf '{"rung":%s,"ok":%s,"nonce":%s,"host_witness":%s,"guest_witness":%s,"guest_client_exit":%s,"guest_output":%s}' \
    "$(json_escape "$label")" "$ok" "$(json_escape "$nonce")" \
    "$(json_escape "$host_ok")" "$(json_escape "$guest_ok")" "$guest_rc" "$(json_escape "$guest_out")")"

  log "$label: host_witness=$host_ok guest_witness=$guest_ok ok=$ok"
  [ "$ok" = true ]
}

# --- entrypoint --------------------------------------------------------------
main() {
  preflight
  assert_snapshot_pristine "$SNAPSHOT_DIR" before
  assert_snapshot_pristine "$SNAPSHOT_DIR" after
}

# e10-lifecycle.sh uses the same escape hatch, for the same reason: the tests
# need to source ONE function without main() immediately demanding /dev/kvm.
if [ "${E12_PROBE_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
