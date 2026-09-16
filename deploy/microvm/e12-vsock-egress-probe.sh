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
