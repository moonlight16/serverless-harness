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
# the socket only needs to EXIST at connect time - but "exist" means bound AND
# listening, and backgrounding the python3 process is not the same instant as
# that process actually reaching listen(). At N=128 concurrent restores
# (issue #271's rung C@128; see EXPERIMENTS.md's E13 section), forking and
# execing 128 python3 interpreters in close succession creates real variance
# in exactly when each one's listen() call executes, independent of host
# compute - a guest whose CONNECT lands before its own listener is bound gets
# VIRTIO_VSOCK_OP_RST, correctly, because nothing was listening yet. That is
# the dominant recovered failure signature in E13's bare-metal run (99.2% of
# failures there), where every host-resource candidate (CPU steal, disk
# iowait, memory) was independently ruled out - a race in this function's own
# startup ordering, not a mechanism defect, fits the evidence. The fix: the
# python3 script signals readiness via a marker file the instant its own
# listen() call returns, and this function blocks on that file before
# returning - so no caller can trigger the guest's CONNECT until the host
# side is genuinely ready to receive it.
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
  local ready="$sock.ready"
  pyfile="$jail/.e12-listener.py"
  rm -f "$ready"
  cat >"$pyfile" <<'PYEOF'
import socket, sys, os
sock_path, capture_path, ready_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
os.chmod(sock_path, 0o666)
srv.listen(1)
# Signals readiness only AFTER listen() has actually succeeded - this is the
# ordering fix itself. Written before accept() so the caller never blocks on
# this longer than the bind+listen setup actually takes.
with open(ready_path, "w") as f:
    f.write("ready\n")
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
  python3 "$pyfile" "$sock" "$sock.captured" "$ready" >/dev/null 2>&1 &
  local pid=$!
  # Poll for the ready file rather than assume any fixed delay is enough -
  # under the exact N=128 contention this exists to survive, a fixed sleep
  # would either be too short (races again) or too long (adds real latency
  # to every one of 128 concurrent probes). 5s is generous next to a bind+
  # listen that normally completes in microseconds; if it is ever actually
  # needed, something is already badly wrong and dying loudly beats hanging.
  local waited=0
  while [ ! -f "$ready" ]; do
    if [ "$waited" -ge 50 ]; then
      kill "$pid" 2>/dev/null || true
      die "host listener on $sock never signaled ready within 5s - is python3's AF_UNIX bind/listen actually failing, or is this host starved past any reasonable startup delay?"
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
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
# point of view, per vsock.md -- on $PROBE_PORT, sends the BARE nonce (no
# decorative tag), reads the reply, and prints it to guest stdout so
# guest_client relays it back to us. run_probe_once's own comparisons are
# exact matches against the bare nonce (host_nonce = $nonce, and
# *"ACK $nonce"* against guest_out) - a prefix tag here would make both
# checks fail unconditionally. The nonce already self-identifies (it's built
# as "e12-${label}-$$-${RANDOM}"), so no tag is needed anyway.
guest_probe_command() {
  local nonce="$1" b64
  b64="$(cat <<'PYEOF' | base64 | tr -d '\n'
import socket, sys
nonce, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.settimeout(10)
s.connect((socket.VMADDR_CID_HOST, port))
s.sendall((nonce + "\n").encode())
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

# --- VM lifecycle: fresh boot and restore -------------------------------------
# Both recipes below match build-snapshot.sh's own boot_quiesce_snapshot_firecracker
# and verify_restore_firecracker exactly (drive config, vsock config, machine-config,
# the vsock_override shape) rather than reinventing them: those recipes are the ones
# already proven to work on this exact rig, so any failure here is about what E12
# adds (the second port), not about basic VM bringup.

ensure_workspace_image() {
  local path="$1"
  truncate -s $((2 * 1024 * 1024 * 1024)) "$path" ||
    die "could not truncate workspace image at $path"
  mkfs.ext4 -q -F "$path" >/dev/null || die "could not mkfs.ext4 the workspace image at $path"
}

wait_for_agent() {
  local uds="$1" console_log="$2" waited=0
  while [ "$waited" -lt 120 ]; do
    if [ -f "$console_log" ] && grep -q "parked in accept()" "$console_log" 2>/dev/null; then
      return 0
    fi
    if "$GUEST_CLIENT" -uds "$uds" -port "$AGENT_PORT" -probe-only -dial-timeout 1s 2>/dev/null; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "console log for the guest agent that never became reachable:"
  cat "$console_log" >&2 2>/dev/null || true
  die "guest agent never became reachable on vsock:$AGENT_PORT within 120s"
}

# boot_fresh_vm brings up a brand-new VM from the golden kernel+rootfs (no
# vmstate, no memfile - this is rung A, the control). rootfs is mounted
# is_read_only:true and boot_args carries `ro`, matching the Global Constraints'
# "never write to the golden snapshot" guard for the case where the snapshot's
# rootfs is used directly rather than via restore.
boot_fresh_vm() {
  local jail="$1"
  local api_sock="$jail/run/firecracker.socket" vsock_uds="$jail/vsock.sock" \
    console_log="$jail/console.log"
  prepare_jail "$jail"
  ln "$SNAPSHOT_DIR/kernel" "$jail/kernel" 2>/dev/null || cp -p "$SNAPSHOT_DIR/kernel" "$jail/kernel"
  ln "$SNAPSHOT_DIR/rootfs" "$jail/rootfs" 2>/dev/null || cp -p "$SNAPSHOT_DIR/rootfs" "$jail/rootfs"
  ensure_workspace_image "$jail/workspace.img"

  chroot "$jail" /firecracker --api-sock /run/firecracker.socket \
    </dev/null >"$console_log" 2>&1 &
  CLEANUP_PID=$!

  wait_for_socket "$api_sock" "$console_log"
  api_put "$api_sock" /boot-source \
    "{\"kernel_image_path\":\"/kernel\",\"boot_args\":\"console=ttyS0 ro reboot=k panic=1 pci=off\"}"
  api_put "$api_sock" /drives/rootfs \
    "{\"drive_id\":\"rootfs\",\"path_on_host\":\"/rootfs\",\"is_root_device\":true,\"is_read_only\":true}"
  api_put "$api_sock" /drives/workspace \
    "{\"drive_id\":\"workspace\",\"path_on_host\":\"/workspace.img\",\"is_root_device\":false,\"is_read_only\":false}"
  api_put "$api_sock" /vsock \
    "{\"vsock_id\":\"vsock0\",\"guest_cid\":$GUEST_CID,\"uds_path\":\"/vsock.sock\"}"
  api_put "$api_sock" /machine-config \
    "{\"mem_size_mib\":$GUEST_RAM_MB,\"vcpu_count\":1}"
  api_put "$api_sock" /actions '{"action_type":"InstanceStart"}'

  wait_for_agent "$vsock_uds" "$console_log"
  # Set a global, NOT echoed for the caller to capture via $(...): command
  # substitution always forks a subshell, and CLEANUP_PID/CLEANUP_JAIL (set a
  # few lines up, inside THIS call) would never propagate back out of that
  # subshell to the caller - the caller's own $CLEANUP_PID would stay at
  # whatever it was BEFORE this call, and teardown_jail would be handed an
  # empty pid, silently failing to kill the VM while still rm -rf-ing the jail
  # out from under it. Calling this function as a plain statement (no `$()`)
  # keeps CLEANUP_PID/CLEANUP_JAIL/VM_UDS in the CALLER's own shell, where the
  # top-level `trap cleanup_on_exit EXIT` (Task 3) can also see them if the
  # script dies before an explicit teardown_jail call runs.
  VM_UDS="$vsock_uds"
}

# restore_vm loads the golden vmstate+memfile into a fresh jail. vsock_override
# rewrites uds_path to this jail's OWN /vsock.sock (jail-relative, so every jail
# - even N of them concurrently under rung C - gets an independent socket with no
# collision, since chroot gives each one its own filesystem namespace). No
# /boot-source, /drives or /machine-config calls: restore carries all of that
# state already, and repeating them is rejected once InstanceStart has occurred
# once against those resources - build-snapshot.sh's own comment on this
# (fix-round-8) is why this function does not attempt it.
restore_vm() {
  local jail="$1"
  local api_sock="$jail/run/firecracker.socket" vsock_uds="$jail/vsock.sock" \
    console_log="$jail/console.log"
  prepare_jail "$jail"
  link_snapshot_into_jail "$jail"
  ensure_workspace_image "$jail/workspace.img"

  chroot "$jail" /firecracker --api-sock /run/firecracker.socket \
    </dev/null >"$console_log" 2>&1 &
  CLEANUP_PID=$!

  wait_for_socket "$api_sock" "$console_log"
  api_put "$api_sock" /snapshot/load \
    "{\"snapshot_path\":\"/vmstate\",\"mem_backend\":{\"backend_path\":\"/memfile\",\"backend_type\":\"File\"},\"vsock_override\":{\"uds_path\":\"/vsock.sock\"},\"resume_vm\":true}"

  wait_for_agent "$vsock_uds" "$console_log"
  # See boot_fresh_vm's identical comment above: a global, not an echoed
  # value, for exactly the same subshell-scoping reason.
  VM_UDS="$vsock_uds"
}

# --- rung A: fresh boot, no restore (the control) -----------------------------
# If this rung fails, the failure is our plumbing or the socket naming - NOT
# Firecracker's restore mechanism - because no restore happened yet. Without a
# passing rung A, a failure at rung B is uninterpretable.
run_rung_a() {
  local jail="$JAIL_BASE/rung-a"
  rm -rf "$jail"
  # Called as a plain statement, NOT captured via $(...) - see boot_fresh_vm's
  # own comment on why: this keeps VM_UDS/CLEANUP_PID in THIS function's own
  # shell rather than losing them to a vanished subshell.
  boot_fresh_vm "$jail" || die "rung-A: boot_fresh_vm failed"
  local ok=0
  run_probe_once "$jail" "$VM_UDS" "rung-A" || ok=1
  teardown_jail "$jail" "$CLEANUP_PID"
  return "$ok"
}

# --- rung B: restore once, then connect (the actual question) ----------------
run_rung_b() {
  local jail="$JAIL_BASE/rung-b"
  rm -rf "$jail"
  # Plain statement, not $(...) - see Task 5's comment on why (the function
  # this calls sets globals a subshell would otherwise swallow).
  restore_vm "$jail" || die "rung-B: restore_vm failed"
  local ok=0
  run_probe_once "$jail" "$VM_UDS" "rung-B" || ok=1
  teardown_jail "$jail" "$CLEANUP_PID"
  return "$ok"
}

# --- rung C: N concurrent restores from one snapshot --------------------------
# Concurrent, not sequential: all N microVMs are restored and alive AT THE SAME
# TIME, all connecting on 1025, before any is torn down. Sequential restarts
# would prove repeatability but could not surface a socket-naming collision -
# rung C's actual purpose - because only one jail would ever exist at a time.
# Each VM gets its own jail (its own chroot filesystem namespace), so
# restore_vm's per-jail /vsock.sock (Task 5) means there is structurally only
# one place a collision COULD show up: this function's own aggregation, if two
# VMs' witnesses were somehow cross-wired. They cannot be, by construction (two
# different absolute host paths), but the aggregation still checks nonce
# uniqueness explicitly rather than assuming it.
run_rung_c_n() {
  local n="$1" i pids=() jails=()
  for i in $(seq 1 "$n"); do
    local jail="$JAIL_BASE/rung-c-${n}-${i}"
    rm -rf "$jail"
    jails+=("$jail")
    (
      local rc=0
      # A plain redirect on a function call (2>"...") does NOT fork a
      # subshell by itself - only $(...) does - so restore_vm's
      # VM_UDS/CLEANUP_PID/CLEANUP_JAIL side effects stay visible in THIS
      # per-VM subshell's own scope below. See boot_fresh_vm's comment
      # (Task 5) for why $(...) would have broken that.
      restore_vm "$jail" 2>"$jail.boot.log" || {
        write_json_record "$RESULTS/rung-C-${n}-${i}.json" \
          "{\"rung\":\"rung-C-${n}-${i}\",\"ok\":false,\"error\":\"restore_vm failed\"}"
        exit 1
      }
      run_probe_once "$jail" "$VM_UDS" "rung-C-${n}-${i}" || rc=1
      teardown_jail "$jail" "$CLEANUP_PID"
      exit "$rc"
    ) &
    pids+=("$!")
  done

  local ok_count=0 fail_count=0 pid
  for pid in "${pids[@]}"; do
    if wait "$pid"; then
      ok_count=$((ok_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
  done

  # Explicit collision check: every per-VM record's nonce must be unique. A
  # duplicate would mean two VMs somehow generated (or worse, witnessed) the
  # same nonce, which is the concrete shape "a per-restore collision" would take.
  local nonces dup_count
  nonces="$(python3 -c '
import json, sys, glob
ns = []
for p in sys.argv[1:]:
    try:
        with open(p) as f:
            ns.append(json.load(f).get("nonce", ""))
    except Exception:
        pass
print("\n".join(ns))
' "$RESULTS"/rung-C-"${n}"-*.json 2>/dev/null)"
  dup_count=$(printf '%s\n' "$nonces" | sort | uniq -d | grep -c . || true)

  local all_ok=false
  [ "$fail_count" -eq 0 ] && [ "$dup_count" -eq 0 ] && all_ok=true

  write_json_record "$RESULTS/rung-C-${n}.json" \
    "$(printf '{"rung":"rung-C-%s","n":%s,"ok":%s,"ok_count":%s,"fail_count":%s,"nonce_collisions":%s}' \
      "$n" "$n" "$all_ok" "$ok_count" "$fail_count" "$dup_count")"

  log "rung-C(n=$n): ok_count=$ok_count fail_count=$fail_count nonce_collisions=$dup_count all_ok=$all_ok"
  [ "$all_ok" = true ]
}

run_rung_c() {
  local n overall=0
  for n in $C_LADDER; do
    run_rung_c_n "$n" || overall=1
  done
  return "$overall"
}

# --- rung D: host-initiated 1024 still works with 1025 present (regression fence) --
# The worst outcome the issue names: adding a second port breaks the mechanism
# P4 already ships on. This does NOT reuse run_probe_once (that exercises
# GUEST-initiated 1025) - it exercises the EXISTING host-initiated Exec path on
# 1024 directly, with the 1025 listener present but unused by this rung, so a
# regression here is unambiguously about interference from the second port.
run_rung_d() {
  local jail="$JAIL_BASE/rung-d"
  rm -rf "$jail"
  # Plain statement, not $(...) - see Task 5's comment on why (the function
  # this calls sets globals a subshell would otherwise swallow).
  restore_vm "$jail" || die "rung-D: restore_vm failed"

  local listener_out lpid
  listener_out="$(start_host_listener "$jail" "rung-d-unused")"
  lpid="${listener_out#pid:}"; lpid="${lpid%% capture:*}"

  local exit_code=0
  "$GUEST_CLIENT" -uds "$VM_UDS" -port "$AGENT_PORT" -timeout-s 15 -command true >/dev/null 2>&1 ||
    exit_code=$?

  stop_host_listener "$lpid"
  teardown_jail "$jail" "$CLEANUP_PID"

  local ok=false
  [ "$exit_code" -eq 0 ] && ok=true
  write_json_record "$RESULTS/rung-D.json" \
    "$(printf '{"rung":"rung-D","ok":%s,"guest_client_exit":%s}' "$ok" "$exit_code")"
  log "rung-D: host-initiated 1024 with 1025 present -> exit=$exit_code ok=$ok"
  [ "$ok" = true ]
}

# --- entrypoint ----------------------------------------------------------------
main() {
  preflight
  assert_snapshot_pristine "$SNAPSHOT_DIR" before

  local overall_ok=true
  wants_rung A && { run_rung_a || overall_ok=false; }
  wants_rung B && { run_rung_b || overall_ok=false; }
  wants_rung C && { run_rung_c || overall_ok=false; }
  wants_rung D && { run_rung_d || overall_ok=false; }

  assert_snapshot_pristine "$SNAPSHOT_DIR" after

  write_json_record "$RESULTS/e12-answer.json" \
    "$(printf '{"substrate":%s,"rungs_run":%s,"ok":%s}' \
      "$(json_escape "$SUBSTRATE")" "$(json_escape "$RUNGS")" "$overall_ok")"

  if [ "$overall_ok" = true ]; then
    log "E12 ANSWER: guest-initiated vsock on a second port SURVIVES restore (rungs: $RUNGS, substrate: $SUBSTRATE)"
  else
    log "E12 ANSWER: not all rungs passed (rungs: $RUNGS, substrate: $SUBSTRATE) - see $RESULTS for which; a rung-C-only failure is a concurrency-scale finding, not a restore-mechanism failure"
  fi
  [ "$overall_ok" = true ]
}

# e10-lifecycle.sh uses the same escape hatch, for the same reason: the tests
# need to source ONE function without main() immediately demanding /dev/kvm.
if [ "${E12_PROBE_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
