# Cloud Hypervisor hands-on tutorial (P4 prep)

Research/learning note, no product code. Companion to
[`firecracker-tutorial.md`](firecracker-tutorial.md) — same purpose (get hands-on with the
primitives [P4](2026-09-09-p4-microvm-sandbox-design.md) depends on before the implementation
plan proceeds), same rigor (every command below was actually run), but pointed at the arm the
spec itself flags as unverified: **§2.4 states plainly that "Cloud Hypervisor's equivalents are
unverified," and §9 calls this "the largest remaining unknown."** This note is step 0 of §10's
build order — "verify Cloud Hypervisor's snapshot caveats against §2.4's Firecracker set" — done
as a hands-on pass rather than a reading exercise.

**This tutorial is written as a running comparison against the Firecracker tutorial**, not a
standalone walkthrough. Wherever Cloud Hypervisor's behavior matches, differs from, or outright
contradicts what the Firecracker note found, that's called out inline — not saved for a summary
at the end. A compact differences table is still included (§11) as a scannable reference, but the
inline callouts are the primary content.

**Status: validated end-to-end on a real KVM host** — same host family as the Firecracker note
(AWS EC2, Amazon Linux 2023, kernel `6.18.44-99.149.amzn2023.x86_64`), 4 vCPUs, 15 GiB RAM,
`/dev/kvm` present, cgroups v2. Cloud Hypervisor **v53.0**, `virtiofsd` **v1.14.0** (built from
source — see §2), guest kernel **6.16.9+** (a pre-built PVH kernel from Cloud Hypervisor's own
`linux` fork, release `ch-release-v6.16.9-20260508`). Every numbered section below was actually
run on that host; several dead ends and one abandoned approach are described in place, because
the failures are as informative as the successes — this is exactly the point of a hands-on pass
before a design decision hardens.

**Target machine**: bare-metal or nested-virt, `/dev/kvm` present. Everything after §1 assumes
you're on that box.

## Conventions, and what's different from the Firecracker note's gotchas

- Scratch directory: `mkdir -p ~/ch-tutorial && cd ~/ch-tutorial`.
- Each section ends with a **cleanup** block and a **maps to spec** line, same convention as the
  Firecracker note.
- **Cloud Hypervisor's serial console has the same stdin-attachment behavior Firecracker's
  Gotcha 1 describes** — `--serial tty` reads/writes the guest's UART against the launching
  process's own stdio. Every backgrounded launch below redirects stdin from the start
  (`< /dev/null > log 2>&1 &`) for that reason; this note didn't have to rediscover the SIGTTIN
  hang because it applied the Firecracker note's fix pre-emptively. If you skip it, expect the
  identical symptom: the process shows `T` in `ps`, and every subsequent API call hangs.
- **No `curl -S` gotcha here** — Cloud Hypervisor's API socket is created with the same
  permissions as the launching user when run under `sudo`, and every call below still uses `sudo
curl` for consistency with how the real daemon will run, but the failure mode Firecracker's
  Gotcha 2 warns about (silent, unhelpful `-s`-only failures) applies equally: use `-s -S` or
  check `$?`, every multi-line call below does.
- **A generic scripting trap worth stating up front, not tied to Cloud Hypervisor specifically**:
  if you write a helper that finds a running VMM by `pgrep -f` / `pkill -f` against a literal
  string, and that helper is itself invoked as `sh -c '...that literal string...'` (for example,
  from a wrapper script or a remote-exec harness), the pattern matches the invoking shell's own
  command line and kills the wrong process. This bit repeatedly while driving the API from a
  scripted SSH session in this pass. It's the reason a real `vmpool` orphan sweep should match on
  something that can't appear in its own invocation — a PID file, a cgroup membership check, or an
  exact `comm` name — not a `pgrep -f` substring. Not a tutorial-worthy repro since it's an
  artifact of scripted remote exec, not of typing commands at a real prompt, but worth remembering
  when `vmpool`'s own crash-recovery sweep (§6, "Worker crash leaks VMs") is implemented.

---

## 1. Prerequisites

Identical checks to the Firecracker note's §1 — this is host capability, not VMM-specific:

```bash
lsmod | grep kvm
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo OK || echo FAIL
grep -Em1 'vmx|svm' /proc/cpuinfo && echo "virt extensions visible" || echo "NONE"
mount | grep cgroup2
cat /sys/fs/cgroup/cgroup.controllers
uname -r
```

On this box `/dev/kvm` was `crw-rw-rw-` already (same as the Firecracker note found on its own
Amazon Linux 2023 box — apparently the AL2023 AMI default, not a per-instance fluke).

**Maps to spec**: §2.4's cgroups v2 requirement is VMM-agnostic — it's a host kernel property,
not something Firecracker or Cloud Hypervisor each impose independently.

---

## 2. Install Cloud Hypervisor, `ch-remote`, and `virtiofsd`

**First difference from Firecracker: there is no jailer binary.** Firecracker ships exactly two
binaries (`firecracker`, `jailer`); Cloud Hypervisor ships two as well, but they're a different
pair — the VMM itself and a thin API CLI client (`ch-remote`), with **no jailer equivalent at
all**. §7 below is what that absence actually costs.

```bash
curl -fsSL -o cloud-hypervisor https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v53.0/cloud-hypervisor-static
curl -fsSL -o ch-remote https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v53.0/ch-remote-static
chmod +x cloud-hypervisor ch-remote
./cloud-hypervisor --version   # cloud-hypervisor v53.0
./ch-remote --version          # ch-remote v53.0
```

Packages needed later (AL2023; swap `dnf` for `apt-get` on Ubuntu as the Firecracker note does):

```bash
sudo dnf install -y socat e2fsprogs jq squashfs-tools openssh-clients acl
```

### `virtiofsd` is not packaged, and the obvious source is a 404

Cloud Hypervisor's own `docs/virtiofs-root.md` says to install `virtiofsd` from the distro's
`qemu-system-common` (Ubuntu) / `qemu-common` (Fedora) package — but that's the **classic C
implementation**, deprecated upstream since v22.0 ("Deprecation of 'Classic' `virtiofsd`" per
Cloud Hypervisor's own release notes), and it's not in AL2023's repos either way. The obvious next
guess, `github.com/rust-vmm/virtiofsd`, is a **404** — that repository doesn't exist; the actual
Rust implementation now lives at `gitlab.com/virtio-fs/virtiofsd`. (A GitHub advisory for a Kata
Containers CVE is what actually names the current location — the project's own docs point at the
dead GitHub URL in several places online.) Build it from source:

```bash
sudo dnf install -y rust cargo libseccomp-devel libcap-ng-devel gcc   # AL2023 ships rust/cargo directly
curl -fsSL -o virtiofsd.tar.gz https://gitlab.com/virtio-fs/virtiofsd/-/archive/main/virtiofsd-main.tar.gz
mkdir -p virtiofsd && tar -xzf virtiofsd.tar.gz -C virtiofsd --strip-components=1
cd virtiofsd && cargo build --release
# error: linking with `cc` failed ... cannot find -lseccomp / -lcap-ng
#   -> the libseccomp-devel/libcap-ng-devel install above is what's missing; rerun cargo build --release
cd .. && cp virtiofsd/target/release/virtiofsd ./virtiofsd-bin   # rename: avoid colliding with the source checkout dir
./virtiofsd-bin --version   # virtiofsd 1.14.0
```

**Maps to spec**: this is exactly the gap §9's risk note is about — Firecracker's toolchain is a
two-binary download; Cloud Hypervisor's virtio-fs story needs a second project, built from source,
fetched from a URL that isn't the one most search results point to. Anyone repeating this later
should start from `gitlab.com/virtio-fs/virtiofsd`, not GitHub.

---

## 3. Get a kernel and rootfs

**Second difference: direct kernel boot needs a PVH-capable kernel, and Cloud Hypervisor publishes
a pre-built one.** Firecracker's `getting-started.md` quickstart fetches a generic kernel + Ubuntu
rootfs from Firecracker's own CI bucket. Cloud Hypervisor's quickstart instead has you **build**
a kernel from `cloud-hypervisor/linux` (`make ch_defconfig && make bzImage`) — but the project also
publishes that exact build as a GitHub release asset, used by its own CI
(`scripts/test_assets.yaml`), which is far less friction than a from-scratch kernel build:

```bash
curl -fsSL -o vmlinux-x86_64 https://github.com/cloud-hypervisor/linux/releases/download/ch-release-v6.16.9-20260508/vmlinux-x86_64
file vmlinux-x86_64   # ELF 64-bit LSB executable, statically linked — a PVH kernel, not bzImage
```

**Third difference, and a nice one: Firecracker's own CI rootfs works unmodified under Cloud
Hypervisor.** Rather than building a new rootfs, this note reused the exact same Ubuntu 24.04
ext4 image the Firecracker tutorial builds in its own §3 — same S3 bucket, same
unsquashfs-and-bake-in-a-key recipe:

```bash
S3="https://s3.amazonaws.com/spec.ccfc.min"
CI_ARTIFACTS_PREFIX=$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
    | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" | sort | tail -1)
latest_ubuntu_key=$(curl -fsSL "$S3?list-type=2&prefix=${CI_ARTIFACTS_PREFIX}x86_64/ubuntu-" \
    | grep -oP "(?<=<Key>)(${CI_ARTIFACTS_PREFIX}x86_64/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" | sort -V | tail -1)
wget -O ubuntu-24.04.squashfs.upstream "$S3/$latest_ubuntu_key"
unsquashfs -q ubuntu-24.04.squashfs.upstream
ssh-keygen -q -f ch_id_rsa -N ""
cp ch_id_rsa.pub squashfs-root/root/.ssh/authorized_keys
sudo chown -R root:root squashfs-root
truncate -s 1G ubuntu-24.04.ext4
sudo mkfs.ext4 -q -d squashfs-root -F ubuntu-24.04.ext4
```

This is not a coincidence worth over-reading — it's just an ext4 filesystem tree with an sshd and
a systemd init, and neither depends on which VMM booted it. It **does** mean anyone building a
real Cloud Hypervisor golden image can validate the rootfs side against Firecracker's own CI
assets before building the purpose-specific one spec §5 wants.

**A fourth, load-bearing difference that cost a kernel panic before it was understood: Cloud
Hypervisor needs an explicit `root=` boot argument; Firecracker does not.** The Firecracker
tutorial's own boot args are `console=ttyS0 reboot=k panic=1` — no `root=` anywhere, and it boots
fine, because Firecracker's `"is_root_device": true` flag on the drive causes Firecracker itself
to arrange for the guest to find its root device without a `root=` argument. Cloud Hypervisor's
`DiskConfig` has no such flag — the first attempt at booting with Firecracker-style boot args
produced, immediately and reproducibly:

```
[    0.618194] Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

Fixed by adding `root=/dev/vda` explicitly:

```
console=ttyS0 root=/dev/vda rw reboot=k panic=1
```

**Maps to spec**: §5.1's guest image layers — same "kernel + rootfs pair, no agent yet" scope as
the Firecracker note. The `root=` difference matters directly for §10's implementation notes: a
`microvm-worker` cmdline template copied verbatim from a Firecracker-flavored mental model will
panic on first boot under Cloud Hypervisor.

---

## 4. First boot, via the API socket directly

**Fifth, and the most structural difference so far: Cloud Hypervisor's API is one JSON blob, not
a PUT per resource.** Firecracker's boot sequence is a `PUT` each to `/machine-config`,
`/boot-source`, `/drives/rootfs`, `/network-interfaces/net1`, then `/actions {InstanceStart}` — five
separate calls building up a config the VMM assembles as it goes. Cloud Hypervisor's equivalent is
**one `/vm.create` call carrying the entire `VmConfig` document**, followed by a bare
`/vm.boot` with no body:

```bash
API_SOCKET=/tmp/ch1.sock
sudo rm -f "$API_SOCKET"
sudo ./cloud-hypervisor --api-socket "$API_SOCKET" < /dev/null > ch1.log 2>&1 &
disown
sleep 1

TAP_DEV=tap0; sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add 172.16.0.1/30 dev "$TAP_DEV"
sudo ip link set dev "$TAP_DEV" up
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -P FORWARD ACCEPT
HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev')
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE

curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$1" \
    -H 'Content-Type: application/json' --data "$3" "http://localhost/api/v1$2"; }

curl_put "$API_SOCKET" /vm.create "{
  \"cpus\": {\"boot_vcpus\": 2, \"max_vcpus\": 2},
  \"memory\": {\"size\": 268435456},
  \"payload\": {\"kernel\": \"$PWD/vmlinux-x86_64\", \"cmdline\": \"console=ttyS0 root=/dev/vda rw reboot=k panic=1\"},
  \"disks\": [{\"path\": \"$PWD/ubuntu-24.04.ext4\", \"readonly\": false}],
  \"net\": [{\"tap\": \"tap0\", \"mac\": \"06:00:AC:10:00:02\"}],
  \"serial\": {\"mode\": \"Tty\"},
  \"console\": {\"mode\": \"Off\"}
}"
curl_put "$API_SOCKET" /vm.boot ""
```

Both calls print `204`. The `06:00:AC:10:00:02` MAC is not arbitrary — it's the **same
MAC-encodes-IP convention** the Firecracker tutorial's CI rootfs uses (last four bytes of the MAC
are the IPv4 address, `AC:10:00:02` = `172.16.0.2`); the guest self-configures that address on
`eth0` at boot via tooling baked into the rootfs itself, independent of which VMM is running it:

```bash
ssh -i ch_id_rsa -o StrictHostKeyChecking=no root@172.16.0.2 "hostname; ip a show eth0"
# ubuntu-fc-uvm
# eth0 ... inet 172.16.0.2/30 ... link/ether 06:00:ac:10:00:02
```

**Sixth difference: `vm.delete` exists and clears in-process state, but a killed VMM process
still holds its API socket path until the process actually exits — same `Address in use`-flavored
trap as Firecracker's stale-socket issue, just at the create layer instead of vsock.** If a second
`vm.create` against a live socket returns `"VM is already created"`, the fix is `vm.delete`
first, not `rm -f` the socket (the file being gone doesn't stop the live process from still
answering on it).

**Cleanup**:

```bash
sudo curl -s -o /dev/null -X PUT --unix-socket "$API_SOCKET" http://localhost/api/v1/vm.delete
sudo kill -9 $(pgrep -x cloud-hypervisor) 2>/dev/null
sudo rm -f "$API_SOCKET"
```

**Maps to spec**: §3.1 — `vmpool` drives exactly this API surface (`vm.create`/`vm.boot`), with no
relay and no harness in the path, same as `vmpoolctl`'s design intent. The one-JSON-blob shape is
actually a slightly better fit for `vmpool.Config` than Firecracker's incremental-PUT shape, since
the whole VM description is assembled host-side in Go before any network call anyway.

---

## 5. vsock — the channel `Exec` will actually use, and Cloud Hypervisor's own docs say why it's similar

Cloud Hypervisor's `docs/vsock.md` states outright that its vsock implementation is **"based on
the Firecracker implementation"** — so the wire mechanics below should look familiar:

```bash
sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data '{"cid": 3, "socket": "'"$PWD"'/ch1.vsock"}' \
    http://localhost/api/v1/vm.add-vsock
```

**Seventh difference, and a genuinely useful one: this hot-adds a vsock device to an already-
running VM.** Firecracker requires `/vsock` to be configured _before_ `InstanceStart` — there is
no add-a-device-after-boot path for it. Cloud Hypervisor's device-hotplug model (`vm.add-vsock`,
also `vm.add-net`, `vm.add-disk`, etc.) means the call above worked against the VM booted in §4
with no reboot, no config replay, nothing.

In the guest, listen with a variant of Firecracker's `socat` trick that avoids its "backgrounded
listener needs a real stdin" gotcha entirely — spawn `cat` as the connection handler instead of
wiring the vsock to `socat`'s own stdio, so there's no controlling-terminal dependency to trip over:

```bash
ssh -i ch_id_rsa root@172.16.0.2 "nohup socat VSOCK-LISTEN:52,fork EXEC:cat < /dev/null > /tmp/s.log 2>&1 &"
```

From the host, the `CONNECT <port>` handshake is byte-for-byte the same convention Firecracker
uses:

```bash
echo -e "CONNECT 52\nHello from CH host!" | sudo socat - UNIX-CONNECT:"$PWD/ch1.vsock"
# OK 1073741824
# Hello from CH host!
```

(The port number in the `OK` line is a much larger ephemeral value than Firecracker's tutorial
example — cosmetic, not a protocol difference.) The `Hello from CH host!` line echoing back
confirms the round trip end to end, with the guest's `cat` echo standing in for a real framed
protocol handler.

**Cleanup**:

```bash
sudo curl -s -o /dev/null -X PUT --unix-socket "$API_SOCKET" http://localhost/api/v1/vm.delete
sudo kill -9 $(pgrep -x cloud-hypervisor) 2>/dev/null
```

**Maps to spec**: §2.4's vsock row, §5.4's parked-agent design. The hot-add capability is not
something the spec currently plans to use (the golden snapshot already includes a configured
vsock device before the standby is even created), but it's worth knowing it exists — it removes
one hard boot-order constraint if a future revision needs it.

---

## 6. Snapshot, restore, multi-resume, and the clock — the section that actually retires §9's risk note

This is the section the whole tutorial exists for. Four things §2.4 asserts for Firecracker and
flags as unverified for Cloud Hypervisor: listening-vsock-survives / established-connections-reset
across restore, the insecurity of resuming one snapshot more than once, the stale-wall-clock trap,
and the underlying "nothing secret in the golden snapshot" invariant. All four are checked below,
against a real snapshot/restore cycle, not against documentation.

### 6a. API shape

Cloud Hypervisor's lifecycle calls are individually simpler than Firecracker's PATCH-then-PUT
pair, and there's a convenience CLI (`ch-remote`) wrapping them — used here via raw `curl` to stay
consistent with §4's driving style and with what `vmpoolctl` would actually issue:

```bash
sudo curl -s -o /dev/null -X PUT --unix-socket "$API_SOCKET" http://localhost/api/v1/vm.pause
sudo curl -s -o /dev/null -X PUT --unix-socket "$API_SOCKET" -H 'Content-Type: application/json' \
    --data "{\"destination_url\": \"file://$PWD/snapA\"}" http://localhost/api/v1/vm.snapshot
```

Three files land in the target directory — `config.json`, `memory-ranges`, `state.json` — a
three-file split that's conceptually the same information Firecracker's two files (`state.json` +
memory file) carry, just with the VM's device/CPU/memory _description_ pulled out into its own
human-readable, **root-owned, 0600** JSON file. Cloud Hypervisor's own docs say this file is
"editable if needed" — confirmed directly in §9 below, where editing a restored snapshot's disk
path is exactly what unblocks a multi-process test.

### 6b. VM A: mint a token, hold a vsock connection open, snapshot, then die without resuming

Boot with vsock configured from the start (§5's hot-add would work too, but including it in
`vm.create` keeps the snapshot's `config.json` self-contained):

```bash
curl_put "$API_SOCKET" /vm.create "{ ... \"vsock\": {\"cid\": 3, \"socket\": \"$PWD/cha.vsock\"}, ... }"
curl_put "$API_SOCKET" /vm.boot ""

ssh -i ch_id_rsa root@172.16.0.2 "cat /proc/sys/kernel/random/uuid > /token; cat /proc/sys/kernel/random/boot_id >> /token"
ssh -i ch_id_rsa root@172.16.0.2 "nohup socat VSOCK-LISTEN:52,fork EXEC:cat < /dev/null > /tmp/s.log 2>&1 &"
```

Establish a connection from the host and **leave it open** through the pause/snapshot — the
Firecracker tutorial does this with a second interactive terminal; the same effect without a
second terminal is a stdin that never EOFs:

```bash
{ echo "CONNECT 52"; tail -f /dev/null; } | sudo socat - UNIX-CONNECT:"$PWD/cha.vsock" > vsock-host.log 2>&1 &
disown
```

Confirm the guest shows two `socat` processes (listener + forked handler) plus the `EXEC:cat`
child before proceeding — this is the "established connection" state the restore test needs to
actually be testing something:

```bash
ssh -i ch_id_rsa root@172.16.0.2 "pgrep -a socat; pgrep -a cat"
# 1131 socat VSOCK-LISTEN:52,fork EXEC:cat
# 1135 socat VSOCK-LISTEN:52,fork EXEC:cat
# 1136 cat
```

Pause, snapshot, then kill VM A **without ever resuming it** — the same "A terminates without
resuming" pattern the Firecracker note's §6a uses:

```bash
sudo curl -s -o /dev/null -X PUT --unix-socket "$API_SOCKET" http://localhost/api/v1/vm.pause
sudo curl -s -o /dev/null -X PUT --unix-socket "$API_SOCKET" -H 'Content-Type: application/json' \
    --data "{\"destination_url\": \"file://$PWD/snapA\"}" http://localhost/api/v1/vm.snapshot
sudo kill -9 $(pgrep -x cloud-hypervisor)
```

### 6c. Restore into VM B, check clock / token / vsock, then restore the _same_ snapshot into VM C

```bash
API_SOCKET_B=/tmp/ch-b.sock
sudo ./cloud-hypervisor --api-socket "$API_SOCKET_B" < /dev/null > chb.log 2>&1 &
disown
sleep 1
echo "host date: $(date -u)"
sudo curl -s -o /dev/null -X PUT --unix-socket "$API_SOCKET_B" -H 'Content-Type: application/json' \
    --data "{\"source_url\": \"file://$PWD/snapA\", \"resume\": true}" http://localhost/api/v1/vm.restore
```

The first attempt at this returned:

```
["Error from API","The VM could not be restored","Error from device manager",
 "Cannot create virtio-vsock backend","Error binding to the host-side Unix socket",
 "Address in use (os error 98)"]
```

**Eighth difference, but this time a genuine parity, not a divergence: Cloud Hypervisor has
exactly the same "you must remove the stale vsock socket file between successive restores of the
same snapshot" trap the Firecracker note's §6b documents** — right down to the identical errno
(`98`, `Address in use`). The snapshot's `config.json` embeds the vsock socket path verbatim, and
whichever process restores it recreates that path; VM A's original `cha.vsock` file was still on
disk from §6b. The fix is the same one-liner:

```bash
rm -f "$PWD/cha.vsock"
# then retry the restore call above -> 204
```

Results, checked immediately after a successful restore:

```bash
ssh -i ch_id_rsa root@172.16.0.2 "date -u; cat /token; pgrep -a socat"
```

- **Token identical** to VM A's (`5bdd5653-...` / `ddf6a224-...`) — confirms the same invariant
  the Firecracker note found: a file materialized _before_ the snapshot comes back byte-identical
  on restore, every time. §5.2's invariant ("nothing secret or unique may exist in the golden
  snapshot") is exactly the mitigation this property demands, and it demands it identically under
  Cloud Hypervisor.
- **Guest clock stale**: host showed `16:24:09`, guest showed `16:21:04` — roughly the real elapsed
  wall-clock gap between snapshot and restore. This is worth dwelling on, because **Cloud
  Hypervisor v53.0's own release notes claim this is fixed**: "the guest clock is now advanced to
  account for the elapsed wall-clock time when a VM is resumed after a snapshot-restore... the
  kvmclock realtime flag is preserved so that the kernel adjusts the clock automatically." It
  visibly didn't take effect here. The reason is the **exact same caveat** the Firecracker note
  found for `clock_realtime`: the fix only applies when the guest's clock source is `kvmclock`,
  and this rootfs's kernel — same CI kernel family both tutorials use — defaults to `tsc`:
  ```bash
  ssh -i ch_id_rsa root@172.16.0.2 "cat /sys/devices/system/clocksource/clocksource0/current_clocksource"
  # tsc
  ```
  So: **both Firecracker's `clock_realtime` flag and Cloud Hypervisor's newer automatic
  clock-advance mechanism share the identical tsc-vs-kvmclock precondition**, and neither fires on
  a `tsc`-clocksource guest. A real implementation needs a guest-side fix (`date -s`, as the
  Firecracker note settles on) regardless of which VMM ships the correction — the VMM-side flag is
  not sufficient by itself on this kernel family.
- **Vsock reset on restore, confirmed**: `pgrep -a socat` after restore shows only the listener
  (`1131`), not the forked handler (`1135`) or the `cat` child. The established connection did not
  survive; the listener did. This matches Cloud Hypervisor's own v52.0 release note ("Vsock
  connections are now reset on snapshot restore to avoid stale half-open connections") and matches
  Firecracker's documented behavior exactly — genuine parity between the two VMMs here, both
  citable rather than assumed.

Now the actual multi-resume test — restore the **same** `snapA` snapshot into a third, independent
process, VM C:

```bash
API_SOCKET_C=/tmp/ch-c.sock
sudo ./cloud-hypervisor --api-socket "$API_SOCKET_C" < /dev/null > chc.log 2>&1 &
disown
sleep 1
rm -f "$PWD/cha.vsock"
sudo curl -s -o /dev/null -X PUT --unix-socket "$API_SOCKET_C" -H 'Content-Type: application/json' \
    --data "{\"source_url\": \"file://$PWD/snapA\", \"resume\": true}" http://localhost/api/v1/vm.restore
```

The first attempt here failed differently — not the vsock socket this time, but the **TAP
device**:

```
["Error from API","The VM could not be restored","Error from device manager",
 "Cannot create virtio-net device","Failed to open taps","Open tap device failed",
 "Unable to configure tap interface","Resource busy (os error 16)"]
```

**Ninth observation, and it's a shared-heritage detail rather than an independent finding: this
error text — "Open tap device failed" / "Resource busy" — is essentially identical to the failure
mode the Firecracker tutorial's §10 describes for the same underlying condition** (a TAP device
attached to a live process can't be attached to a second one concurrently). That's very likely not
coincidence: Cloud Hypervisor and Firecracker are both `rust-vmm`-ecosystem VMMs and plausibly
share lineage in their `net_util`/tap-handling code. The fix is the mundane one — VM B (the actual
live holder of `tap0`) had not been killed yet:

```bash
sudo kill -9 <VM B's actual PIDs>   # then retry the restore above -> 204
```

Checked on VM C immediately post-restore:

```bash
ssh -i ch_id_rsa root@172.16.0.2 "cat /token; cat /proc/sys/kernel/random/uuid; pgrep -a socat"
```

- Token: **identical** to A and B again.
- `pgrep -a socat`: listener only, same as B — the reset-on-restore behavior holds across a
  _second_ restore of the same snapshot too, not just the first.
- A fresh `/proc/sys/kernel/random/uuid` draw **differed** between B's first post-restore draw and
  C's (`74da2652-...` vs `64197fec-...`).

That last point deserves care, because it's the one place this tutorial can't hand the spec a
clean verdict. **Searching Cloud Hypervisor's own repository for VMGenID (the mechanism
Firecracker's docs cite, and which §2.4's table attributes the "VMGenID reseeds the kernel PRNG on
Linux ≥5.18" claim to) turns up nothing — zero open or closed pull requests, zero release-note
mentions.** Cloud Hypervisor appears to have **no VMGenID-equivalent device at all**. And yet B and
C's first random draws differed, which is not what "no reseed mechanism, identical PRNG state"
would predict on its own. The honest read: something — plausibly interrupt-timing jitter during
each restore's own network/vsock setup, feeding the kernel's entropy pool through an ordinary,
undedicated path — introduced _some_ divergence, but this tutorial did not isolate the cause, and
one trial of two draws is not evidence of a guaranteed property. **This is squarely the kind of gap
§9's risk note exists to flag**: Firecracker gives you a _documented, named, versioned_ mechanism
with a stated kernel-version precondition; Cloud Hypervisor, on this evidence, gives you nothing
you can name and nothing you can be confident holds under adversarial conditions. Fortunately, this
doesn't touch the spec's own security argument — §5.2 is explicit that "duplicated guest ASLR is
not a boundary we rely on: the attacker already executes arbitrary code inside the guest, and our
boundary is KVM" — so nothing here weakens the design. It does mean a Cloud Hypervisor-specific
version of §5.2's invariant should say "no reseed mechanism is known to exist" rather than
gesturing at a Firecracker-shaped one that isn't actually present.

**Cleanup**:

```bash
sudo kill -9 $(pgrep -x cloud-hypervisor) 2>/dev/null
sudo rm -f /tmp/ch-*.sock "$PWD"/cha.vsock*
```

**Maps to spec**: §5.2's invariant (demonstrated, and the VMGenID half specifically **not**
confirmed present under Cloud Hypervisor — see above), §2.4's vsock-reset-on-restore row
(confirmed, matches Firecracker), §2.4/§5.3's stale-wall-clock trap (confirmed, and shown to share
Firecracker's exact tsc-vs-kvmclock precondition despite a newer, ostensibly-fixed mechanism), and
§10 step 0's whole reason for existing.

---

## 7. The missing jailer — cgroups v2 memory bounds without one

**Tenth, and the most structurally significant difference for the spec's own architecture: Cloud
Hypervisor has nothing resembling the jailer.** §5.3 of the spec leans on Firecracker's jailer for
two things at once — the chroot that makes "bind the run's workspace at a fixed path" work, and the
`--cgroup` flags that give each VM its own memory-bounded cgroup. Cloud Hypervisor supplies
**neither**. Whatever isolation and cgroup placement `microvm-worker` needs under the Cloud
Hypervisor arm has to be built by the caller, not configured on a supplied sandboxing tool.

This section reproduces the Firecracker tutorial's §8 (a ballooning guest gets OOM-killed inside
its own cgroup, not the host's) using `systemd-run --scope` as the substitute for jailer's
`--cgroup` flag:

```bash
sudo systemd-run --unit=ch-cgtest --scope -p MemoryMax=200M --property=Delegate=yes -- \
    ./cloud-hypervisor --api-socket "$PWD/ch-cg.sock" < /dev/null > chcg.log 2>&1 &
disown
sleep 1
cat /sys/fs/cgroup/system.slice/ch-cgtest.scope/memory.max   # 209715200 (200 MiB) — confirmed landed
```

Boot a VM configured for 512 MiB of guest RAM — deliberately more than the 200 MiB cgroup allows —
and dirty ~400 MiB of it via tmpfs, exactly as the Firecracker note does:

```bash
ssh -i ch_id_rsa -o ServerAliveInterval=3 -o ServerAliveCountMax=2 root@172.16.0.2 \
    "dd if=/dev/zero of=/dev/shm/fill bs=1M count=400"
```

The SSH session dies mid-command. On the host:

```bash
sudo dmesg | grep -iE 'oom|memory cgroup' | tail -5
```

```
oom-kill:constraint=CONSTRAINT_MEMCG,...,oom_memcg=/system.slice/ch-cgtest.scope,task=cloud-hyperviso,pid=53568,uid=0
Memory cgroup out of memory: Killed process 53568 (cloud-hyperviso) total-vm:550428kB, anon-rss:203316kB,...
```

Scoped to the cgroup, by name, exactly as Firecracker's jailer-plus-`--cgroup` test shows — and the
rest of the host is untouched:

```bash
uptime; free -h
#  load average: 0.00, 0.02, 0.06
#  Mem: 15Gi total, 329Mi used, 14Gi available
```

**The mechanism transfers cleanly; the packaging does not.** `systemd-run --scope` gets identical
_results_ to jailer's `--cgroup memory.max=...`, but it's a different integration shape: no chroot
comes bundled with it, no `--uid`/`--gid`/`--chroot-base-dir` story, and nothing analogous to
jailer's "hard-link the resources you need into the jail" convention that makes §5.3's per-run
workspace binding work. A real `vmpool` on the Cloud Hypervisor arm needs to build that chroot (or
equivalent confinement) itself — most plausibly via a plain Linux mount namespace plus bind mount,
since that's the same primitive jailer itself uses under the hood, minus the packaging.

**Cleanup**:

```bash
sudo pkill -9 -x cloud-hypervisor 2>/dev/null
# the transient scope disappears on its own once its only process dies
```

**Maps to spec**: §6's mitigation #3 ("`memory.max` on each VM's cgroup... one failed `Exec`,
attributable, instead of a host-level lottery") — the _outcome_ spec wants is fully achievable
under Cloud Hypervisor. §5.3's jailer-chroot-as-per-run-workspace mechanism, however, has **no
supplied equivalent** on this arm — that's new information for the implementation notes, not
something §5.3 as written currently accounts for.

---

## 8. virtio-fs — the reason Cloud Hypervisor is in scope at all, tested for real

§4.3's decisive row: Firecracker's D>1 standbys are "impossible as specified" because two guest
kernels can't both mount one ext4 block device read-write without corrupting it, while Cloud
Hypervisor's virtio-fs arm is "fine — the host filesystem arbitrates." This section builds that
topology for real: **two independently running guests, two independent `virtiofsd` processes,
one shared host directory** — and proves concurrent writes from both land correctly.

### 8a. A dead end worth keeping: `--cache=auto` disconnects immediately

The first attempt, following Cloud Hypervisor's own `docs/virtiofs-root.md` example almost
verbatim:

```bash
sudo ./virtiofsd-bin --socket-path="$PWD/vfs.sock" --shared-dir=/tmp/ch-workspace-demo --cache=auto < /dev/null > vfs.log 2>&1 &
disown
```

`vfs.log` showed the connection come up, then immediately drop:

```
[INFO virtiofsd] Waiting for vhost-user socket connection...
[INFO virtiofsd] Client connected, servicing requests
[INFO virtiofsd] Client disconnected, shutting down
```

Cloud Hypervisor's own log for the same attempt eventually surfaced the real failure, after a full
minute of silent retrying (the VMM does not fail fast on a dead vhost-user backend — it retries for
~60 seconds before giving up, which reads exactly like a hang until you wait it out):

```
ERROR ... Failed connecting the backend after trying for 1 minute for socket .../vfs.sock:
  VhostUserProtocol(SocketConnect(Os { code: 111, kind: ConnectionRefused, ... }))
Fatal error: ... Error rebooting VM ... Cannot create virtio-fs device ...
```

This tutorial did not fully root-cause the `cache=auto` disconnect — it's plausibly a feature-
negotiation mismatch touching the deprecated DAX-style caching path §2.4 already flags as removed
(virtiofsd dropped DAX in 2024; Cloud Hypervisor deprecated DAX-based virtio-fs in 2022) — but the
practical fix was immediate and repeatable:

```bash
sudo ./virtiofsd-bin --socket-path="$PWD/vfs.sock" --shared-dir=/tmp/ch-workspace-demo --cache=never < /dev/null > vfs.log 2>&1 &
```

With `--cache=never`, the connection stayed up through every subsequent test in this section, no
exceptions. **Anyone repeating this should start from `--cache=never`**, not from the quickstart
doc's `--cache=never` — wait, the quickstart doc's own example actually already uses
`--cache=never` (this tutorial's first attempt deviated from it, reaching for `auto` on the
assumption that "more caching" would be a safe default to start from; it was not).

### 8b. VM D and VM E, two independent `virtiofsd` processes, one shared directory

```bash
mkdir -p /tmp/ch-workspace-demo
echo "hello from the host" > /tmp/ch-workspace-demo/greeting.txt

# VM D's virtiofsd
sudo ./virtiofsd-bin --socket-path="$PWD/vfs.sock"  --shared-dir=/tmp/ch-workspace-demo --cache=never < /dev/null > vfs.log  2>&1 &
disown
# VM E's virtiofsd -- a SEPARATE process, SAME --shared-dir
sudo ./virtiofsd-bin --socket-path="$PWD/vfs2.sock" --shared-dir=/tmp/ch-workspace-demo --cache=never < /dev/null > vfs2.log 2>&1 &
disown
```

Each VM gets its own tap device, its own disk image (a fresh `rootfs-*.ext4` copy each — see the
note on disk reuse in §9), `memory.shared=true` (**required** for virtio-fs — a vhost-user daemon
needs `MAP_SHARED` access to guest RAM, unlike the plain `MAP_PRIVATE` default Firecracker's
snapshot mechanism assumes per §2.4), and an `fs` entry pointing at its own `virtiofsd` socket:

```json
"memory": {"size": 268435456, "shared": true},
"fs": [{"tag": "workspace", "socket": "<vfs.sock or vfs2.sock>", "num_queues": 1, "queue_size": 1024}]
```

Mount in both guests, then write from each and read back from the other:

```bash
# VM E (172.16.0.6)
ssh -i ch_id_rsa root@172.16.0.6 "mkdir -p /workspace && mount -t virtiofs workspace /workspace && \
    cat /workspace/greeting.txt && echo VM_E_WROTE_THIS > /workspace/from-e.txt"
# hello from the host

# VM D (172.16.0.2)
ssh -i ch_id_rsa root@172.16.0.2 "mkdir -p /workspace && mount -t virtiofs workspace /workspace && \
    cat /workspace/from-e.txt && echo VM_D_WROTE_THIS > /workspace/from-d.txt"
# VM_E_WROTE_THIS
```

And on the host, both files landed cleanly, with no coordination between the two guests at all:

```bash
cat /tmp/ch-workspace-demo/from-d.txt /tmp/ch-workspace-demo/from-e.txt
# VM_D_WROTE_THIS
# VM_E_WROTE_THIS
```

**This is the central claim §4.3 makes about the virtio-fs arm, confirmed directly**: two
independently booted guest kernels, each running its own filesystem code, wrote and read a shared
host directory concurrently with zero corruption and zero synchronization on the guest side —
because neither guest ever touches a shared block device; each `virtiofsd` process does ordinary,
host-arbitrated file I/O against the same directory, and the host kernel's own VFS handles the
concurrency the way it always does for two host processes sharing a directory. This is exactly why
D>1 standbys are viable here and are not on the Firecracker block-device arm: the sharing happens
at the host filesystem layer, once, rather than inside two guest ext4 drivers that have no way to
coordinate with each other.

**Cleanup**:

```bash
sudo pkill -9 -x cloud-hypervisor 2>/dev/null
sudo pkill -9 -x virtiofsd-bin 2>/dev/null
```

**Maps to spec**: §4.3's decisive table row, confirmed by direct test rather than by reading
virtio-fs's design intent off a wiki page. §3.5's `virtiofsd`-must-not-run-as-root warning is
worth flagging as **not yet exercised** here — every `virtiofsd` in this tutorial ran under
`sudo` for simplicity, exactly the posture §3.5 says is unacceptable in production
(`--sandbox=namespace` unprivileged mode is the documented fix, untested in this pass).

---

## 9. Page-cache sharing across restored VMs — the one place this tutorial cannot hand the spec a clean win

§7.3's sharpest trap, quoted directly from the spec: _"summing RSS across 200 processes multiplies
the shared set by 200... reporting ~50 GiB where the truth is ~2 GiB."_ The Firecracker tutorial
demonstrates the fix (`vmtouch -dl`, `MAP_PRIVATE`, sum `Pss` not `VmRSS`) cleanly, with a real
~3× RSS/PSS gap across three processes sharing one snapshot memory file. This tutorial tried to
reproduce the same experiment under Cloud Hypervisor and **did not get the same clean result** —
worth reporting exactly as found, because it bears directly on whether §7.3's memory-budget
arithmetic transfers to the Cloud Hypervisor arm unmodified.

### 9a. `memory_restore_mode=CopyOnWrite` — described in Cloud Hypervisor's upstream docs, not in v53.0

Cloud Hypervisor's docs describe three restore memory modes: `Copy` (eager, default), `OnDemand`
(lazy, via userfaultfd), and `CopyOnWrite` — the last explicitly described as mapping "the
snapshot file copy-on-write so pages are shared across VMs restored from the same snapshot," i.e.
the Cloud Hypervisor analogue of Firecracker's `vmtouch`+`MAP_PRIVATE` trick. Passing it produced:

```
["Failed to deserialize JSON","unknown variant `CopyOnWrite`, expected `Copy` or `OnDemand` at line 1 column 113"]
```

**`CopyOnWrite` is not in the v53.0 release this tutorial installed** — it exists only in the
upstream documentation for a newer or in-development version. This is worth stating plainly rather
than working around silently: as of this pass, the _documented_ mechanism for exactly the
page-sharing property §7.3 needs **is not available in Cloud Hypervisor's current stable
release**.

### 9b. `OnDemand` mode, tried instead — no cross-process sharing observed

Restoring the same headless snapshot into three separate processes with `memory_restore_mode:
OnDemand`, `resume: false` (vCPUs never run, matching the Firecracker tutorial's own approach to
avoid conflating "guest touched its RAM" with "restore mechanism populated it"):

```bash
sudo curl -s -X PUT --unix-socket "$PWD/pss-1.sock" -H 'Content-Type: application/json' --data \
    "{\"source_url\": \"file://$PWD/snapPSS\", \"resume\": false, \"memory_restore_mode\": \"OnDemand\"}" \
    http://localhost/api/v1/vm.restore
```

A real, separate obstacle surfaced first: restoring a **second** process against a snapshot whose
`config.json` still names the original disk path fails, because Cloud Hypervisor holds an
**advisory write lock on disk images** that Firecracker does not:

```
["Error from API","The VM could not be restored","Error locking disk images: Another instance likely holds a lock",
 "Cannot lock images of all block devices","Failed to get Write lock for disk image: .../rootfs-d.ext4","The file is already locked"]
```

Cloud Hypervisor's own docs call `config.json` "editable if needed" — confirmed by fixing this
directly, editing the JSON in place to strip the `disks` array entirely for the memory-only
experiment (`python3 -c 'import json; d=json.load(open(p)); d["disks"]=[]; json.dump(d, open(p,"w"))'`),
which is both a real workaround and a small validation of that specific claim in §6a.

With disks removed and all three processes successfully restored, `VmRSS` and `Pss`
(`/proc/<pid>/smaps_rollup`) per process:

```
PID 54103: VmRSS 267856 kB   Pss 264694 kB
PID 54136: VmRSS 267860 kB   Pss 264666 kB
PID 54226: VmRSS 267860 kB   Pss 264666 kB
```

**No meaningful RSS/PSS gap** — each process's `Pss` is ~99% of its own `VmRSS`, which is the
signature of _unshared_ memory, not shared memory (if the ~256 MiB guest image were genuinely
shared three ways, each process's `Pss` should land near a third of its `VmRSS`, the way the
Firecracker tutorial's ~15.4 MiB→~5.6 MiB compression showed). This also contradicts the naive
expectation from the Firecracker tutorial's own finding that unresumed VMs (`resume_vm: false`)
show only a few MiB of RSS (bookkeeping only, no guest pages touched) — here, `OnDemand` mode
populated nearly the _entire_ guest memory footprint into each process despite no vCPU ever
running.

**This tutorial does not have a confirmed explanation, and says so rather than guessing one.**
The two live candidates: (a) `OnDemand`'s userfaultfd-based population may resolve each fault into
a private, per-process anonymous page rather than a shared mapping of the snapshot file — which
would explain both observations (full population, because eager copies of _something_ still
happen or the restore-time validation pass touches every page, plus no sharing, because each
process's fault handler writes its own private copy) — or (b) genuine cross-process page sharing
of restored guest RAM is simply a `CopyOnWrite`-mode feature that v53.0 doesn't ship, and `Copy`/
`OnDemand` were never intended to provide it. Either way, the practical conclusion is the same:

**§7.3's memory-density arithmetic — "unmodified pages are shared host page cache across every
VM," "the dominant term... computable rather than empirical" — has not been demonstrated to hold
for Cloud Hypervisor in the version tested here, and the one mechanism upstream documents for it
(`CopyOnWrite`) is not yet in a released version.** This is the single highest-priority follow-up
this tutorial surfaces: before §7.3's density numbers are trusted for the Cloud Hypervisor arm,
someone needs to either (a) get `CopyOnWrite` from a newer build and re-run this exact test, or
(b) find a different mechanism (e.g. `mergeable`/KSM against `shared=on` memory, which the
`memory.md` doc describes independently of restore mode) that gives the same sharing property, or
(c) accept that Cloud Hypervisor's per-VM memory cost is closer to Firecracker's naive
"~50 GiB for 200 VMs" reading than to the `vmtouch`-corrected "~2 GiB" one, on this release.

**Cleanup**:

```bash
sudo pkill -9 -x cloud-hypervisor 2>/dev/null
```

**Maps to spec**: §7.3's "Use PSS, not RSS" callout — the accounting _method_ (read `Pss` from
`smaps_rollup`, not `VmRSS`) is unaffected and just as necessary under Cloud Hypervisor. The
underlying _sharing mechanism_ the accounting method exists to correctly measure is the open
question flagged above, and it is now §9's single most consequential unresolved item, ahead of
the vsock/clock items §6 already retired.

---

## 10. A rough, informal preview of E10's lifecycle numbers

Same disclaimer the Firecracker tutorial gives its own §11: **this is not E10.** Treat every
number below as an order of magnitude on a shared, nested-virt instance, not a benchmark.

```bash
# cold boot, from vm.boot to sshd answering
time (
  sudo curl -s -o /dev/null -X PUT --unix-socket "$API_SOCKET" http://localhost/api/v1/vm.boot
  until ssh -i ch_id_rsa -o ConnectTimeout=1 -o StrictHostKeyChecking=no root@172.16.0.2 true 2>/dev/null; do sleep 0.05; done
)
```

Then pause, snapshot, kill, and time restore (paused, not resumed) and resume-from-paused
separately, exactly as the Firecracker tutorial does:

| Step                                               | Cloud Hypervisor (this box) | Firecracker (same box family, per its own tutorial) |
| -------------------------------------------------- | --------------------------- | --------------------------------------------------- |
| Cold boot → sshd answering                         | **~1.76 s**                 | ~1.9 s                                              |
| Restore-from-snapshot, paused, default `Copy` mode | **~141 ms**                 | ~37 ms                                              |
| Restore-from-snapshot, paused, `OnDemand` mode     | **~92 ms**                  | (no equivalent lazy mode measured)                  |
| Resume-from-paused (already restored)              | **~17–19 ms**               | ~17 ms                                              |

The directional relationship §3.2 predicts holds on both VMMs: cold boot ≫ restore >
resume-from-paused. **Resume is essentially identical between the two VMMs** — unsurprising, since
that step is dominated by kicking off vCPU execution, not by how memory got backed. **Restore is
notably slower under Cloud Hypervisor's default `Copy` mode** (~4× Firecracker's number on this
box) — plausibly because `Copy` mode eagerly copies the full memory-ranges file into guest RAM
synchronously during the restore call itself, a cost Firecracker's plain `MAP_PRIVATE`-of-a-file
approach defers until pages are actually touched during execution, so the two numbers are not
measuring quite the same thing. `OnDemand` mode narrows the gap somewhat (~92 ms vs. ~141 ms) by
deferring some of that cost, but does not close it to Firecracker's ~37 ms. This is exactly the
kind of measurement §7.5's "warmup vs steady state" and "closed-loop driver hides queueing" traps
exist to keep a five-line `time` loop from over-interpreting — a real E10 rung, decomposed per
§7.2's table (spawn → restore → pause → ready, wall _and_ CPU time, cold memfile vs pinned), is
what would actually settle whether this gap is real or an artifact of which restore mode was
compared against which Firecracker step.

**Maps to spec**: §7.2's E10 rungs 2–3 (warm hot path, replenishment unit cost) — a sanity check
before the real driver exists, not a substitute for it, and a first concrete (if informal) signal
that the two VMMs' restore costs may not be directly comparable without controlling for restore
mode.

---

## 11. Differences from the Firecracker tutorial, at a glance

| Area                             | Firecracker                                                                   | Cloud Hypervisor                                                                                                           |
| -------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Toolchain                        | 2 binaries (`firecracker`, `jailer`)                                          | 2 binaries (`cloud-hypervisor`, `ch-remote`) + a **third-party** `virtiofsd` build                                         |
| Jailer / chroot                  | Built in, drives per-run workspace binding (§5.3)                             | **None** — chroot/cgroup confinement must be hand-built (§7)                                                               |
| API shape                        | Incremental `PUT` per resource, then `InstanceStart`                          | One `vm.create` (full config), then bare `vm.boot`; devices hot-pluggable after boot too                                   |
| Root device on cmdline           | Not needed (`is_root_device` flag suffices)                                   | **Required** (`root=/dev/vda`) or an immediate kernel panic                                                                |
| vsock config timing              | Must be set before `InstanceStart`                                            | Hot-addable post-boot (`vm.add-vsock`)                                                                                     |
| vsock wire protocol              | `CONNECT <port>` handshake                                                    | Same handshake — CH's own docs say "based on the Firecracker implementation"                                               |
| Vsock reset on restore           | Documented                                                                    | Confirmed independently, matches Firecracker's behavior and its own v52.0 release note                                     |
| Stale wall clock on restore      | `clock_realtime` flag, needs guest `kvmclock` clocksource                     | Automatic clock-advance (v53.0), **same** `kvmclock` precondition, same non-effect on `tsc`                                |
| VMGenID / PRNG reseed on restore | Documented, versioned (guest kernel ≥5.18)                                    | **No equivalent mechanism found** (0 hits searching the repo) — open question, not a green light                           |
| Stale-socket-on-restore trap     | Yes (`Address in use`, vsock)                                                 | Yes, **same errno 98**, same fix                                                                                           |
| Disk image locking               | None observed                                                                 | **Advisory write-lock per disk image** — blocks concurrent restores sharing one disk path                                  |
| D>1 concurrent standbys          | **Impossible as specified** — shared ext4 block device corrupts               | **Works** — independent `virtiofsd` processes per VM, host filesystem arbitrates (§8, confirmed)                           |
| Memory-sharing restore mode      | `MAP_PRIVATE` + `vmtouch -dl`, works out of the box, ~3× RSS/PSS gap measured | `CopyOnWrite` documented upstream but **not in the installed v53.0**; `OnDemand` tried instead, showed **no sharing** (§9) |
| Cache-mode footgun               | N/A                                                                           | `--cache=auto` silently disconnects; `--cache=never` is the working default                                                |
| Cold boot                        | ~1.9 s (this box family)                                                      | ~1.76 s — comparable                                                                                                       |
| Restore (paused)                 | ~37 ms                                                                        | ~92–141 ms depending on restore mode — **notably slower** on this box                                                      |
| Resume-from-paused               | ~17 ms                                                                        | ~17–19 ms — essentially identical                                                                                          |

---

## What this tutorial deliberately skips

- **A real guest agent.** Same as the Firecracker note — `socat`/`cat` stand in for the actual
  `guestagent` package.
- **`virtiofsd` running unprivileged.** Every instance in §8 ran under `sudo`; §3.5's warning that
  a root `virtiofsd` is "host root and would render the microVM boundary decorative" is real and
  untested here. `--sandbox=namespace` is the documented next step.
- **Building or testing a jailer-equivalent chroot.** §7 shows the cgroup half of the missing
  jailer's job; the chroot half (per-run workspace binding at a fixed in-guest path) is flagged as
  a gap, not built.
- **Resolving §9's open question.** Whether Cloud Hypervisor can actually deliver §7.3's shared-
  page-cache density mechanism — via a newer release's `CopyOnWrite`, via KSM, or via something
  else — is left open, deliberately, rather than guessed at.
- **Live migration / snapshot offload.** Cloud Hypervisor's `vm.send-migration`/
  `vm.receive-migration` path (which the `CopyOnWrite` restore mode's docs describe as sharing
  machinery with) is out of scope here, same as it's out of scope for the spec.
- **A cross-instance-type restore test.** Everything here restored on the same host it was
  snapshotted on; §2.4's "restore requires identical hardware/software" claim for Firecracker was
  not independently checked for Cloud Hypervisor.

---

_Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>_
