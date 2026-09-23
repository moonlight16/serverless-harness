# Firecracker hands-on tutorial (P4 prep)

Research/learning note, no product code. Written to get hands-on with the Firecracker
primitives [P4](2026-09-09-p4-microvm-sandbox-design.md) depends on — snapshot/restore, vsock,
the jailer chroot, cgroups v2 memory bounds, and the block-device workspace mechanism — before
the [implementation plan](../plans/2026-09-10-p4-microvm-sandbox.md) is started. It is **not** a
rehearsal of the real `vmpool` design: no golden snapshot with a parked guest agent, no
jailer-driven workspace lifecycle, no A/B harness. It is the minimum hands-on path to "I have
personally seen this Firecracker behavior happen," so the spec's citations of Firecracker's own
docs (§2.4) stop being things you're trusting and become things you've watched.

**Status: validated end-to-end on a real KVM host** (an AWS EC2 instance running Amazon Linux
2023, kernel 6.18, Firecracker v1.17.0) — every numbered section below was actually run, and
several bugs and one wrong claim that a first draft had are fixed in place, with the real findings
folded into the prose. The **Amazon Linux** commands in this note are therefore first-hand. The
**Ubuntu** commands are Firecracker's own `getting-started.md`/`jailer.md`/`vsock.md`/
`snapshotting/snapshot-support.md` wording (Ubuntu is upstream's own worked example) and were
cross-checked line-by-line but not independently re-run on an Ubuntu box in this pass — if you hit
a mismatch there, it's almost certainly a small package-name or path drift, not a wrong mechanism.
Fix it in place.

**Target machine**: bare-metal or nested-virt, **Ubuntu or Amazon Linux 2023** (or another
RHEL-family distro — swap `dnf` for `yum`/`microdnf` as needed), with `/dev/kvm`. Everything after
§1 assumes you're on that box, not this repo checkout. Wherever a command differs by distro, both
variants are given.

## Conventions, and two gotchas that will otherwise burn an hour each

- All commands assume a scratch directory: `mkdir -p ~/fc-tutorial && cd ~/fc-tutorial`.
- `$KERNEL`, `$ROOTFS`, `$SSH_KEY` are set once in §3 and reused in later sections. If you open a
  new shell, re-derive them: `KERNEL=$PWD/$(ls vmlinux-* | tail -1)`,
  `ROOTFS=$PWD/$(ls *.ext4 | tail -1)`, `SSH_KEY=$PWD/$(ls *.id_rsa | tail -1)`.
- Each section ends with a **cleanup** block and a **maps to spec** line. Run cleanup before
  moving to the next section if you want a clean slate.
- These are Firecracker's own CI test assets — kernel, rootfs, the whole setup — same disclaimer
  the upstream docs give: **fine for learning, not for production.**

**Gotcha 1 — always background Firecracker/jailer with `< /dev/null`.** Firecracker attaches the
guest's serial console (`console=ttyS0`) to its own stdin/stdout by default. Launch it with plain
`sudo ./firecracker --api-sock "$API_SOCKET" &` in an interactive shell and the kernel delivers
`SIGTTIN` the moment it tries to read that controlling terminal — the whole process (and the VM
inside it) silently freezes in job-control-stopped state (`ps` shows `T`), and every subsequent API
call just hangs with no error. Every backgrounded launch in this note redirects stdin explicitly:

```bash
sudo ./firecracker --api-sock "$API_SOCKET" < /dev/null > fc.log 2>&1 &
FC_PID=$!
```

If a curl call to a socket you just booted seems to hang forever, this is almost always why —
`ps -o pid,stat,cmd -p $FC_PID` and look for `T` instead of `S`.

**Gotcha 2 — every direct API call needs `sudo`, and `curl -s` hides the reason it failed.**
Firecracker and jailer are both launched with `sudo` in this note (they need `/dev/kvm`), so the
API socket they create is root-owned and a non-root `curl` gets a silent, unhelpful failure. Define
this once per shell session and use it instead of bare `curl`:

```bash
curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data "$2" "http://localhost$1"; }
```

`-S` alongside `-s` is deliberate: plain `-s` silences **both** the progress meter and error
messages, so a permission-denied connect fails with zero output and looks exactly like success. For
one-off `PATCH`/`snapshot/*` calls that aren't a simple `PUT` with a body, use
`sudo curl ... -s -S ...` directly and check `$?` — every such call below does.

---

## 1. Prerequisites

```bash
# KVM kernel module present
lsmod | grep kvm

# read/write access to /dev/kvm
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo OK || echo FAIL
```

If that prints `FAIL`:

```bash
# ACL-based distros
sudo setfacl -m u:${USER}:rw /dev/kvm

# group-based distros
getent group kvm                 # confirm the group exists
ls -l /dev/kvm                   # confirm it's group-owned by kvm
groups                           # is your user already in it?
sudo usermod -aG kvm ${USER}     # if not — then log out/in (or `newgrp kvm`) for it to take effect
```

(On a fresh Amazon Linux 2023 EC2 instance, `/dev/kvm` was already world read/write —
`crw-rw-rw-` — so neither branch was needed there. Ubuntu more commonly gates it behind the `kvm`
group; don't assume either default, check.)

```bash
# hardware virtualization extensions visible to this kernel (relevant if this
# box is itself a nested-virt VM, e.g. a C8i/M8i/R8i instance per spec §1)
grep -Em1 'vmx|svm' /proc/cpuinfo && echo "virt extensions visible" || echo "NONE — KVM will fail to load"

# cgroups v2 unified hierarchy mounted, with the memory controller available
mount | grep cgroup2
cat /sys/fs/cgroup/cgroup.controllers   # should list "memory" among others

# host kernel version — not the ≥5.18 requirement itself (that's the *guest*
# kernel's VMGenID support, spec §2.4), but worth knowing what you're on
uname -r
```

**Maps to spec**: §2.4's "cgroups v1 causes high restore latency; v2 strongly recommended" fact,
and the ≥5.18 guest-kernel requirement for VMGenID PRNG reseed (verified hands-on in §6).

---

## 2. Install Firecracker + jailer

```bash
ARCH="$(uname -m)"
release_url="https://github.com/firecracker-microvm/firecracker/releases"
latest=$(basename $(curl -fsSLI -o /dev/null -w '%{url_effective}' ${release_url}/latest))
curl -L ${release_url}/download/${latest}/firecracker-${latest}-${ARCH}.tgz | tar -xz

mv release-${latest}-${ARCH}/firecracker-${latest}-${ARCH} ./firecracker
mv release-${latest}-${ARCH}/jailer-${latest}-${ARCH} ./jailer
chmod +x firecracker jailer

./firecracker --version
./jailer --version
```

Record the version you got (`$latest`) somewhere — the jailer doc is explicit that **jailer and
firecracker must be the same version**, and both must be the musl static build (the default;
avoid the experimental gnu build). This is a toy version of what §5.5 means by "pinned by a hash
over kernel + rootfs + agent, verified at daemon start": a version/binary mismatch is exactly the
kind of drift that check exists to catch.

Optionally install system-wide once you're happy with the version:

```bash
sudo mv firecracker jailer /usr/local/bin/
```

**If you do this, every `./firecracker` and `./jailer` invocation in the rest of this tutorial
needs its `./` dropped** (just `firecracker`, just `jailer`) — every later section was written and
validated assuming the binaries stay in `~/fc-tutorial`. Miss one and the symptom is confusing
rather than obviously fatal: a backgrounded `sudo ./firecracker --api-sock ... < /dev/null >
fc.log 2>&1 &` with a missing binary fails immediately and near-silently (the shell's own "No such
file or directory" lands wherever that backgrounded job's stderr goes, not in your foreground
output), and every subsequent `curl --unix-socket` call then just fails to connect with no
obviously-related error. If in doubt, skip this step and keep working from `~/fc-tutorial` for the
rest of the tutorial — that's what every command below assumes.

Now the tools later sections need. Package names diverge slightly by distro:

```bash
# Ubuntu
sudo apt-get update
sudo apt-get install -y socat vmtouch e2fsprogs jq squashfs-tools openssh-client acl

# Amazon Linux 2023 (or another RHEL-family distro; use `yum` if `dnf` isn't present)
sudo dnf install -y socat e2fsprogs jq squashfs-tools openssh-clients acl iptables-legacy
```

Two AL2023-specific notes:

- **`vmtouch` isn't packaged for AL2023** (no match in the default repos). It's a single C file
  with no dependencies, so build it — needed only for §10:
  ```bash
  sudo dnf install -y git gcc make
  git clone --depth 1 https://github.com/hoytech/vmtouch.git /tmp/vmtouch-src
  make -C /tmp/vmtouch-src
  sudo cp /tmp/vmtouch-src/vmtouch /usr/local/bin/vmtouch
  ```
- **The package is `openssh-clients` (plural)** on AL2023/RHEL-family, `openssh-client` (singular)
  on Ubuntu — the kind of drift that's obvious once it bites and invisible until then.

**Maps to spec**: §5.5, "pin an exact binary, fail loudly on mismatch" — the golden-snapshot
version of this same discipline.

---

## 3. Get a kernel and rootfs

This is Firecracker's own quickstart script (`docs/getting-started.md`), fetching the latest
kernel + Ubuntu rootfs their CI publishes — **distro-independent**, since it's just downloading a
generic guest image regardless of what your host runs. Confirmed working verbatim on Amazon Linux
2023:

```bash
ARCH="$(uname -m)"
S3="https://s3.amazonaws.com/spec.ccfc.min"

CI_ARTIFACTS_PREFIX=$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
    | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" \
    | sort | tail -1)

latest_kernel_key=$(curl -fsSL "$S3?list-type=2&prefix=${CI_ARTIFACTS_PREFIX}${ARCH}/vmlinux-" \
    | grep -oP "(?<=<Key>)(${CI_ARTIFACTS_PREFIX}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
    | sort -V | tail -1)
wget "$S3/${latest_kernel_key}"

latest_ubuntu_key=$(curl -fsSL "$S3?list-type=2&prefix=${CI_ARTIFACTS_PREFIX}${ARCH}/ubuntu-" \
    | grep -oP "(?<=<Key>)(${CI_ARTIFACTS_PREFIX}${ARCH}/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \
    | sort -V | tail -1)
ubuntu_version=$(basename $latest_ubuntu_key .squashfs | grep -oE '[0-9]+\.[0-9]+')
wget -O ubuntu-$ubuntu_version.squashfs.upstream "$S3/$latest_ubuntu_key"

# the CI rootfs ships no SSH keys — generate one and bake the public half in
unsquashfs ubuntu-$ubuntu_version.squashfs.upstream
ssh-keygen -f id_rsa -N ""
cp -v id_rsa.pub squashfs-root/root/.ssh/authorized_keys
mv -v id_rsa ./ubuntu-$ubuntu_version.id_rsa
sudo chown -R root:root squashfs-root
truncate -s 1G ubuntu-$ubuntu_version.ext4
sudo mkfs.ext4 -d squashfs-root -F ubuntu-$ubuntu_version.ext4

KERNEL=$PWD/$(ls vmlinux-* | tail -1)
ROOTFS=$PWD/$(ls *.ext4 | tail -1)
SSH_KEY=$PWD/$(ls *.id_rsa | tail -1)
echo "KERNEL=$KERNEL"; echo "ROOTFS=$ROOTFS"; echo "SSH_KEY=$SSH_KEY"
```

On the validation run this produced kernel `vmlinux-6.18.44` and `ubuntu-24.04.ext4` — your
versions will differ as CI rolls forward; that's expected, the script always takes the latest.

**What this rootfs is missing, deliberately out of scope here**: the real P4 golden snapshot
needs a purpose-built rootfs with a static guest agent parked in `accept()` (spec §5) — that's the
actual implementation, not something a tutorial should hand-roll. Everything below uses SSH or a
raw `socat` listener as a stand-in for "something is alive in the guest to talk to."

**Maps to spec**: §5.1's guest image layers — this is the "kernel + rootfs" pair without the agent
or the writable-tmpfs discipline.

---

## 4. First boot, via the API socket directly

Firecracker exposes everything through a Unix-socket HTTP API. `vmpool` will drive this same API
(minus jailer, minus network — see §7), so it's worth hand-rolling the `curl` calls once instead
of reaching for `firectl`.

```bash
API_SOCKET=/tmp/fc1.socket
sudo rm -f "$API_SOCKET"
sudo ./firecracker --api-sock "$API_SOCKET" < /dev/null > fc1.log 2>&1 &
FC_PID=$!
sleep 0.3

curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data "$2" "http://localhost$1"; }

curl_put /machine-config '{"vcpu_count":2,"mem_size_mib":256,"smt":false}'
curl_put /boot-source "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}"
curl_put /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS\",\"is_root_device\":true,\"is_read_only\":false}"
```

Every call above should print `204`. If one doesn't, check `ps -o pid,stat,cmd -p $FC_PID` for a
`T` (stopped) state before anything else — see Gotcha 1.

Networking — a TAP device on the host, a matching MAC/IP pair in the guest (`getting-started.md`,
`network-setup.md`). This part is identical on Ubuntu and Amazon Linux:

```bash
TAP_DEV=tap0; TAP_IP=172.16.0.1; MASK_SHORT=/30
sudo ip link del "$TAP_DEV" 2>/dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
sudo ip link set dev "$TAP_DEV" up
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -P FORWARD ACCEPT
HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev')
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE

FC_MAC="06:00:AC:10:00:02"   # last 4 bytes encode the guest IP: AC:10:00:02 = 172.16.0.2
curl_put /network-interfaces/net1 "{\"iface_id\":\"net1\",\"guest_mac\":\"$FC_MAC\",\"host_dev_name\":\"$TAP_DEV\"}"

curl_put /actions '{"action_type":"InstanceStart"}'
sleep 2

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@172.16.0.2 \
  "ip route add default via 172.16.0.1 dev eth0; echo 'nameserver 8.8.8.8' > /etc/resolv.conf"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@172.16.0.2   # interactive shell in the guest
```

If SSH doesn't come up, the CI rootfs also has a console login as a fallback: attach to the
`firecracker` process's stdout (it's the serial console) and use `root` for both login and
password. Run `reboot` inside the guest to gracefully stop Firecracker (it has no guest power
management, so this is the clean-shutdown path, not a real reboot).

**Cleanup**:

```bash
sudo kill -9 $FC_PID 2>/dev/null; sudo rm -f "$API_SOCKET"
```

**Maps to spec**: §3.1 — `vmpool` drives exactly this API (`InstanceStart`, drives, boot-source)
directly, with no relay and no harness in the path, same as `vmpoolctl`.

---

## 5. vsock — the channel `Exec` will actually use

P4's guest agent talks over vsock, not the network — §5.4's parked `bash` is reached this way, and
the harness never gives a VM network access. This section proves the plumbing with `socat` instead
of a real framed protocol.

Add a vsock device **before** boot (repeat §4's boot sequence with one extra call before
`InstanceStart`):

```bash
API_SOCKET=/tmp/fc2.socket
sudo rm -f "$API_SOCKET"
sudo ./firecracker --api-sock "$API_SOCKET" < /dev/null > fc2.log 2>&1 &
FC_PID=$!
sleep 0.3

curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data "$2" "http://localhost$1"; }

curl_put /machine-config '{"vcpu_count":2,"mem_size_mib":256,"smt":false}'
curl_put /boot-source "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}"
curl_put /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS\",\"is_root_device\":true,\"is_read_only\":false}"
curl_put /vsock "{\"guest_cid\":3,\"uds_path\":\"$PWD/fc2.vsock\"}"
curl_put /network-interfaces/net1 "{\"iface_id\":\"net1\",\"guest_mac\":\"06:00:AC:10:00:02\",\"host_dev_name\":\"tap0\"}"
curl_put /actions '{"action_type":"InstanceStart"}'
sleep 2

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@172.16.0.2 \
  "ip route add default via 172.16.0.1 dev eth0; ls /dev/vsock && which socat"
```

`socat` was already present on the Ubuntu CI test rootfs (no `apt-get install` needed inside the
guest). If yours doesn't have it, install it there the normal way for whatever the guest distro is.

**Open a second terminal** (or a second `ssh` session you leave in the foreground) into the guest,
and start a listener there:

```bash
ssh -i "$SSH_KEY" root@172.16.0.2
# now inside the guest:
socat VSOCK-LISTEN:52,fork -
```

Don't try to shortcut this by backgrounding the listener over one SSH call with stdin redirected
to `/dev/null` (`ssh ... "socat VSOCK-LISTEN:52,fork - </dev/null &"`) — it looks like it should
work and silently doesn't. `socat`'s `-` address relays the vsock connection to its own
stdin/stdout; with stdin already at EOF (`/dev/null`), the connection tears down the instant it's
accepted. This is the vsock-section version of Gotcha 1: something in the chain needs a real,
open-ended stdin, and a backgrounded one-liner doesn't have one.

From the **host**, connect through the Unix-domain-socket proxy Firecracker exposes and hand-shake
the vsock port (`"CONNECT <port>\n"` → `"OK <hostside_port>\n"`, per `vsock.md`). Remember Gotcha
2 — the UDS is root-owned because Firecracker was launched with `sudo`:

```bash
sudo socat - UNIX-CONNECT:$PWD/fc2.vsock
CONNECT 52
# expect: OK <some number> — then type into this socat and see it echoed in the guest's terminal
```

That's the whole mechanism: two live processes, a Unix socket standing in for a vsock port, text
flowing both ways.

**What this section does _not_ prove** — and don't try to prove it with a bare Pause/Resume — is
§2.4's "listening sockets survive restore, established connections don't." That distinction is
real, but it's keyed specifically to the **snapshot** lifecycle (`SnapshotCreate`/`SnapshotResume`
events, per `snapshotting/snapshot-support.md`'s "Vsock device reset" section), not to a plain
`PATCH /vm {state: Paused}` / `{state: Resumed}` pair with no snapshot involved. Confirmed directly:
pausing and resuming the _same_ process without ever calling `/snapshot/create` leaves an
established vsock connection completely alive — it's the wrong experiment for that specific claim.
§6 does the real one, because §6 is already doing a genuine snapshot/restore cycle.

**Cleanup**:

```bash
sudo kill -9 $FC_PID 2>/dev/null; sudo rm -f "$API_SOCKET" "$PWD"/fc2.vsock*
```

**Maps to spec**: §2.4's vsock-across-restore fact (proven properly in §6), §5.4's
parked-`bash`-in-`accept()` design.

---

## 6. Snapshot, restore, and the "never resume twice" property

This is the section worth spending the most time on: it's where the spec's most consequential
citation — "resuming one snapshot more than once is documented as insecure" (§5.2) — stops being
a sentence you're taking on faith. It also carries the vsock-reset proof deferred from §5, since
this is the section that actually does a snapshot/restore cycle.

### 6a. Boot VM A, mint something "unique", snapshot, and walk away

```bash
API_SOCKET=/tmp/fc3.socket
sudo rm -f "$API_SOCKET"
sudo ./firecracker --api-sock "$API_SOCKET" < /dev/null > fc3.log 2>&1 &
FC_PID=$!
sleep 0.3

curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data "$2" "http://localhost$1"; }

curl_put /machine-config '{"vcpu_count":2,"mem_size_mib":256,"smt":false}'
curl_put /boot-source "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}"
curl_put /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS\",\"is_root_device\":true,\"is_read_only\":false}"
curl_put /vsock "{\"guest_cid\":3,\"uds_path\":\"$PWD/fc3.vsock\"}"
curl_put /network-interfaces/net1 '{"iface_id":"net1","guest_mac":"06:00:AC:10:00:02","host_dev_name":"tap0"}'
curl_put /actions '{"action_type":"InstanceStart"}'
sleep 2

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@172.16.0.2 "ip route add default via 172.16.0.1 dev eth0"

# stand in for "a cryptographic token minted once" — VMGenID (guest kernel ≥5.18) will
# reseed the kernel's own PRNG on every resume, but it cannot un-mint an already-written
# file. This is exactly the distinction §5.2's invariant is about.
ssh -i "$SSH_KEY" root@172.16.0.2 "cat /proc/sys/kernel/random/uuid > /token; cat /proc/sys/kernel/random/boot_id >> /token; cat /token"
```

Now start (and leave running, in a second terminal) a vsock listener, and connect to it from the
host, exactly as in §5 — this is what lets us prove the connection-reset half of §2.4's claim in a
moment:

```bash
# second terminal, inside the guest:
socat VSOCK-LISTEN:52,fork -

# host:
sudo socat - UNIX-CONNECT:$PWD/fc3.vsock
CONNECT 52
# leave this connected
```

Pause and snapshot — note the `sudo` and the `-s -S`, per Gotcha 2. Forgetting `sudo` here doesn't
error loudly; it just makes the whole rest of this section a no-op that _looks_ like it ran:

```bash
sudo curl --unix-socket "$API_SOCKET" -s -S -X PATCH http://localhost/vm -d '{"state":"Paused"}'
sudo curl --unix-socket "$API_SOCKET" -s -S -X PUT http://localhost/snapshot/create -d "{
    \"snapshot_type\": \"Full\",
    \"snapshot_path\": \"$PWD/snap.state\",
    \"mem_file_path\": \"$PWD/snap.mem\"
}"
sudo chown $(id -u):$(id -g) "$PWD/snap.state" "$PWD/snap.mem"
```

**A terminates without ever resuming** — this is spec §5.2's "Example 1: secure usage" pattern:

```bash
sudo kill -9 $FC_PID
```

Your open `sudo socat - UNIX-CONNECT:...` session from above should now be dead (the process
already died, so this alone doesn't prove the vsock-specific claim — that comes next, from a
process that's still alive when the snapshot is taken).

### 6b. Restore into a fresh VM B, read the token, check vsock, resume into VM C, read it again

The snapshot's vsock config (the `fc3.vsock` path) is embedded in the snapshot state and gets
recreated verbatim by whichever process restores it — **you must remove the stale socket file
between successive restores of the same snapshot**, or the next restore fails with
`Address in use (os error 98)`. (`vsock_override` on `/snapshot/load` is the documented way to
avoid this if you want two restores live at once; sequential restores just need the `rm -f`.)

```bash
restore_and_check() {
  local sock=$1
  sudo rm -f "$sock" "$PWD/fc3.vsock"
  sudo ./firecracker --api-sock "$sock" < /dev/null > "$(basename $sock).log" 2>&1 &
  local pid=$!
  sleep 0.3
  sudo curl --unix-socket "$sock" -s -S -X PUT http://localhost/snapshot/load -d "{
      \"snapshot_path\": \"$PWD/snap.state\",
      \"mem_backend\": {\"backend_path\": \"$PWD/snap.mem\", \"backend_type\": \"File\"},
      \"resume_vm\": true
  }"
  sleep 1
  echo "--- token from this resume ---"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@172.16.0.2 "cat /token"
  echo "--- host wall clock vs guest wall clock ---"
  echo "host: $(date -u)"
  ssh -i "$SSH_KEY" root@172.16.0.2 "date -u"
  echo "--- vsock: how many socat processes survived the restore? ---"
  ssh -i "$SSH_KEY" root@172.16.0.2 "pgrep socat | wc -l"   # expect 1 (the listener), not 2
  echo "--- a fresh connection to the same still-listening port still works ---"
  echo -e "CONNECT 52" | sudo socat - UNIX-CONNECT:"$PWD/fc3.vsock"
  # graceful shutdown so the network/tap can be reused by the next restore
  ssh -i "$SSH_KEY" root@172.16.0.2 "reboot" 2>/dev/null
  sleep 1
  sudo kill -9 "$pid" 2>/dev/null
}

restore_and_check /tmp/fc-vmB.socket   # "VM B"
restore_and_check /tmp/fc-vmC.socket   # "VM C"
```

Before the snapshot, `pgrep socat` in the guest showed **2** processes — the listening parent plus
the forked child servicing your connected `sudo socat` session. After each restore it shows **1**:
the listener survived, the established connection's forked handler didn't. That's spec §2.4's row
made concrete instead of cited, and it's specifically a **restore** effect — §5 already showed the
same bare Pause/Resume does _not_ do this.

You should see **the same token both times** on B and C — that's spec §5.2's invariant made
concrete: kernel randomness generated _after_ boot gets reseeded by VMGenID (check with
`cat /proc/sys/kernel/random/uuid` freshly on each — _that_ value differs between B and C, because
it's drawn from the reseeded pool), but anything already materialized into a file before the
snapshot was taken is baked in and comes back identical every time.

You should also see the **guest clock frozen at snapshot time** on both B and C, rather than
reflecting the actual wall-clock moment of the restore — the stale-clock trap spec §5.3 calls out.
Fix it the way the implementation plan actually does (guest-side `date -s`, not a VMM config field
— see `docs/plans/2026-09-10-p4-microvm-sandbox.md`'s "Spec Deviations" #5):

```bash
ssh -i "$SSH_KEY" root@172.16.0.2 "date -s @$(date -u +%s)"
```

There is also a VMM-level knob for the same problem — `clock_realtime: true` on the
`/snapshot/load` request (requires **host** Linux ≥5.16). It's worth trying once, but don't be
surprised if it silently does nothing: it only takes effect when the guest's clock source is
`kvmclock`, and the CI test kernel used here defaults to `tsc` —

```bash
ssh -i "$SSH_KEY" root@172.16.0.2 "cat /sys/devices/system/clocksource/clocksource0/current_clocksource"
# tsc  →  clock_realtime:true will have no visible effect; the guest-side date -s above is the
#         fix that's actually distro/kernel-independent, and what the implementation plan uses.
```

**Cleanup**:

```bash
sudo pkill -9 -f 'firecracker --api-sock /tmp/fc-vm' 2>/dev/null
sudo pkill -9 -f 'api-sock /tmp/fc3.socket' 2>/dev/null
sudo rm -f /tmp/fc3.socket /tmp/fc-vmB.socket /tmp/fc-vmC.socket "$PWD"/fc3.vsock*
```

**Maps to spec**: §5.2's invariant (demonstrated, not cited), §2.4's vsock-reset-on-restore fact
(demonstrated, and shown to be a restore-specific effect §5 doesn't trigger), §2.4/§5.3's
stale-wall-clock fact, and the VMGenID ≥5.18 fact.

---

## 7. The jailer chroot — how per-run workspaces will actually work

The jailer has **no** `--bind`-style flag for pulling host resources into the jail. Per
`jailer.md`: _"the user must create hard links for (or copy) any resources... inside the jailed
root folder."_ This section does exactly that, plus a `mount --bind` for the one thing jailer
itself won't help with: a per-run workspace directory at a fixed in-jail path — spec §5.3's whole
mechanism.

```bash
CHROOT_BASE=$PWD/jail
ID=tutorial-vm-1
JUID=$(id -u); JGID=$(id -g)   # use your own uid/gid — it must already have /dev/kvm access (§1)

mkdir -p "$CHROOT_BASE/firecracker/$ID/root"
CHROOT_DIR="$CHROOT_BASE/firecracker/$ID/root"

# resources referenced by relative path in the API calls below must exist inside the jail
sudo cp "$KERNEL" "$CHROOT_DIR/vmlinux"
sudo cp "$ROOTFS" "$CHROOT_DIR/rootfs.ext4"

# the workspace: a host directory bind-mounted at a fixed in-jail path — this is the
# mechanism, not a container volume mount or a jailer feature
mkdir -p /tmp/fc-workspace-demo
echo "hello from the host" > /tmp/fc-workspace-demo/greeting.txt
sudo mkdir -p "$CHROOT_DIR/workspace"
sudo mount --bind /tmp/fc-workspace-demo "$CHROOT_DIR/workspace"

sudo chown -R "${JUID}:${JGID}" "$CHROOT_BASE"

sudo ./jailer --id "$ID" \
    --exec-file "$PWD/firecracker" \
    --uid "$JUID" --gid "$JGID" \
    --chroot-base-dir "$CHROOT_BASE" \
    --cgroup-version 2 \
    -- --api-sock /run/firecracker.socket < /dev/null > jailer1.log 2>&1 &
sleep 0.3

ls -la "$CHROOT_DIR"          # firecracker binary, vmlinux, rootfs.ext4, workspace/, run/, dev/
cat jailer1.log                # "API server started" confirms the jail actually came up
API_SOCKET="$CHROOT_DIR/run/firecracker.socket"

curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data "$2" "http://localhost$1"; }

# paths are relative to the jail's new root ("/"), not the host filesystem
curl_put /machine-config '{"vcpu_count":2,"mem_size_mib":256,"smt":false}'
curl_put /boot-source '{"kernel_image_path":"./vmlinux","boot_args":"console=ttyS0 reboot=k panic=1"}'
curl_put /drives/rootfs '{"drive_id":"rootfs","path_on_host":"./rootfs.ext4","is_root_device":true,"is_read_only":false}'
curl_put /network-interfaces/net1 '{"iface_id":"net1","guest_mac":"06:00:AC:10:00:02","host_dev_name":"tap0"}'
curl_put /actions '{"action_type":"InstanceStart"}'
sleep 2

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@172.16.0.2 "ip route add default via 172.16.0.1 dev eth0; lsblk; ls /workspace 2>&1 || echo 'not visible in guest yet'"
```

The guest reports "not visible in guest yet" — and that's expected. The bind mount above only puts
the host directory at a fixed path **inside the jail's chroot**, which is host-side. Firecracker
still needs a device (a drive, in Firecracker's case — see §9) pointing the _guest_ at that path; a
directory bind-mounted into the chroot isn't automatically a guest mount. This section's point is
narrower and still worth the friction: confirm the file is where the jail expects it, from the
**host's** view of the chroot:

```bash
cat "$CHROOT_DIR/workspace/greeting.txt"   # "hello from the host" — reachable at a fixed jail path
```

**On `--cgroup-version`**: with `--cgroup-version 2` and no `--cgroup` flag, jailer does **not**
create a new cgroup — it only _moves_ the process into `--parent-cgroup` if that path already
exists (jailer.md). §8 adds a `--cgroup memory.max=...` flag, which — combined with `-v2` — makes
jailer actually create `<id>`'s own cgroup and write the value in. This is exactly the "jailer's
own `--cgroup` args must be configured consistently with the systemd slice §6 relies on, or the two
mechanisms fight" trap spec §5.3 calls out — you've now seen the two different code paths that can
disagree.

**Cleanup**:

```bash
ssh -i "$SSH_KEY" root@172.16.0.2 "reboot" 2>/dev/null
sleep 1
sudo pkill -9 -f "jailer --id $ID"
sudo umount "$CHROOT_DIR/workspace" 2>/dev/null
sudo rm -rf "$CHROOT_BASE"
```

**Maps to spec**: §5.3's whole jailer-chroot-as-per-run-workspace mechanism; §5.3's cgroup-args
warning.

---

## 8. cgroups v2: a ballooning guest dies in its own cgroup, not the host's

Spec §6 mitigation #3: _"`memory.max` on each VM's cgroup, so a ballooning command is killed
inside its own cgroup — one failed `Exec`, attributable, instead of a host-level lottery."_ Repeat
§7's jailer boot, but cap the cgroup below the guest's configured RAM so a guest workload that
dirties enough pages gets OOM-killed at the cgroup boundary.

```bash
ID=tutorial-vm-2
CHROOT_BASE=$PWD/jail2
JUID=$(id -u); JGID=$(id -g)
mkdir -p "$CHROOT_BASE/firecracker/$ID/root"
CHROOT_DIR="$CHROOT_BASE/firecracker/$ID/root"
sudo cp "$KERNEL" "$CHROOT_DIR/vmlinux"
sudo cp "$ROOTFS" "$CHROOT_DIR/rootfs.ext4"
sudo chown -R "${JUID}:${JGID}" "$CHROOT_BASE"

# 200 MiB cgroup limit, guest configured for 512 MiB of RAM — the guest CAN allocate
# more than the cgroup allows, which is the point
sudo ./jailer --id "$ID" \
    --exec-file "$PWD/firecracker" \
    --uid "$JUID" --gid "$JGID" \
    --chroot-base-dir "$CHROOT_BASE" \
    --cgroup-version 2 \
    --cgroup memory.max=200M \
    -- --api-sock /run/firecracker.socket < /dev/null > jailer2.log 2>&1 &
sleep 0.3

API_SOCKET="$CHROOT_DIR/run/firecracker.socket"
curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data "$2" "http://localhost$1"; }
curl_put /machine-config '{"vcpu_count":2,"mem_size_mib":512,"smt":false}'
curl_put /boot-source '{"kernel_image_path":"./vmlinux","boot_args":"console=ttyS0 reboot=k panic=1"}'
curl_put /drives/rootfs '{"drive_id":"rootfs","path_on_host":"./rootfs.ext4","is_root_device":true,"is_read_only":false}'
curl_put /network-interfaces/net1 '{"iface_id":"net1","guest_mac":"06:00:AC:10:00:02","host_dev_name":"tap0"}'
curl_put /actions '{"action_type":"InstanceStart"}'
sleep 2
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@172.16.0.2 "ip route add default via 172.16.0.1 dev eth0"

# confirm the limit actually landed — cgroup_base=/sys/fs/cgroup, parent_cgroup defaults to
# exec_file_name ("firecracker"), so the path is deterministic:
cat "/sys/fs/cgroup/firecracker/$ID/memory.max"   # → 209715200 (200 MiB in bytes)

# dirty ~400 MiB of guest RAM via tmpfs — well under the guest's 512MiB but over the
# host cgroup's 200MiB. Give it a dead-connection timeout: the guest is about to die
# mid-command, and plain ssh will otherwise hang indefinitely waiting for a TCP response
# that's never coming.
ssh -i "$SSH_KEY" -o ServerAliveInterval=3 -o ServerAliveCountMax=2 root@172.16.0.2 \
  "dd if=/dev/zero of=/dev/shm/fill bs=1M count=400"
```

Watch what happens on the host — `dmesg` needs `sudo` on most distros (`dmesg_restrict` blocks a
plain user from reading the kernel ring buffer, confirmed on this Amazon Linux box: a bare `dmesg`
fails with `Operation not permitted`):

```bash
sudo dmesg | grep -iE 'oom|out of memory|memory cgroup' | tail -10
```

A real run produced exactly this — the kill is scoped to the cgroup, naming the jailed process by
PID, not a host-wide event:

```
Memory cgroup out of memory: Killed process 35619 (firecracker) total-vm:534664kB, anon-rss:202752kB, ...
```

Confirm the rest of the host is unaffected — this cgroup's failure didn't touch anything outside
`<id>`'s slice:

```bash
uptime; free -h   # load average near zero, memory basically untouched
ps aux | grep firecracker   # the jailed process for tutorial-vm-2 is gone; nothing else is
```

**Cleanup** (note `rmdir`, not `rm -rf` — cgroupfs's pseudo-files can't be removed individually,
only the now-empty directory can be):

```bash
sudo pkill -9 -f "jailer --id $ID"
sudo rmdir "/sys/fs/cgroup/firecracker/$ID" 2>/dev/null
sudo rm -rf "$CHROOT_BASE"
```

**Maps to spec**: §6 mitigation #3 exactly — "a ballooning command is killed inside its own
cgroup... instead of a host-level lottery."

---

## 9. The workspace is a block device, not a shared filesystem

Firecracker has no virtio-fs (spec §2.4) — the workspace is a second drive, and §4.3's whole
"Firecracker + per-run block image" column hinges on one operational fact: **`sync` before kill is
mandatory**, because the guest's page cache dies with the VM. This section proves that, then
proves the fix.

```bash
API_SOCKET=/tmp/fc4.socket
rm -f workspace.img
truncate -s 256M workspace.img
sudo mkfs.ext4 -q -F workspace.img

sudo rm -f "$API_SOCKET"
sudo ./firecracker --api-sock "$API_SOCKET" < /dev/null > fc4.log 2>&1 &
FC_PID=$!
sleep 0.3
curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data "$2" "http://localhost$1"; }
curl_put /machine-config '{"vcpu_count":2,"mem_size_mib":256,"smt":false}'
curl_put /boot-source "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}"
curl_put /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS\",\"is_root_device\":true,\"is_read_only\":false}"
curl_put /drives/workspace "{\"drive_id\":\"workspace\",\"path_on_host\":\"$PWD/workspace.img\",\"is_root_device\":false,\"is_read_only\":false}"
curl_put /network-interfaces/net1 '{"iface_id":"net1","guest_mac":"06:00:AC:10:00:02","host_dev_name":"tap0"}'
curl_put /actions '{"action_type":"InstanceStart"}'
sleep 2
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ServerAliveInterval=3 -o ServerAliveCountMax=2 root@172.16.0.2 \
  "ip route add default via 172.16.0.1 dev eth0; lsblk; mkdir -p /workspace; mountpoint -q /workspace || mount /dev/vdb /workspace 2>&1 || (mkfs.ext4 -F /dev/vdb && mount /dev/vdb /workspace); df -h /workspace"
```

Confirmed on the validation run: `/dev/vda` is the rootfs, `/dev/vdb` the workspace — virtio-blk
devices enumerate in the order the drives were added via the API. The `lsblk` above is there so you
can double check rather than trust that ordering blindly.

**A real bug the original form of this command had, found and fixed in place**: `mount /dev/vdb
/workspace 2>&1 || (mkfs.ext4 -F /dev/vdb; mount ...)` treats _any_ mount failure as "not yet
formatted" and reformats. But `/dev/vdb` being **already mounted** — e.g. because you re-ran this
block, or SSH'd back in after the first run already succeeded — _also_ makes `mount` exit
non-zero, which triggers the exact same fallback: `mkfs.ext4 -F` then runs against a device that is
currently mounted and live. This is not a theoretical risk — it was hit directly while preparing
this note: the second run's `mount` failed with `/dev/vdb already mounted on /workspace`, the
fallback fired, and the guest's `dmesg` immediately showed real corruption —
`EXT4-fs error (device vdb): htree_dirblock_to_tree:1051: inode #2: comm ls: Directory block failed
checksum` — from `mkfs` rewriting the on-disk structure out from under the kernel's still-live view
of the old mount. Recovering needed an `umount` (which itself failed with `Structure needs
cleaning`) followed by a full `mkfs.ext4 -F` while genuinely unmounted. The command above now
guards with `mountpoint -q /workspace ||` first, so the fallback only ever fires when the device
truly isn't mounted yet.

**Two things worth being deliberate about before running this section.** First, `mkfs.ext4 -q`
alone does **not** skip the interactive "this file already contains a filesystem, proceed anyway?"
prompt — `-q` only quiets normal progress output, and that prompt is a separate safety check gated
by `-F`. Re-running this section against an already-256M `workspace.img` (from a previous pass)
hangs a scripted run waiting on stdin for exactly this reason; `rm -f workspace.img` before the
`truncate`, plus `-F` on `mkfs.ext4`, avoids it. Second, and more consequential: **kill every
Firecracker/jailer instance from earlier sections before starting this one.** `tap0` can only be
attached to one running VM at a time (§10 makes this explicit for headless snapshot-loading, but
it bites here too), and a forgotten VM from §7 or §8 left running for hours will silently eat the
`network-interfaces` PUT call in this section with a `400` — check `ps aux | grep -E
'firecracker|jailer'` first if anything here doesn't add up.

### 9a. Without sync — kill and see what survives

```bash
ssh -i "$SSH_KEY" root@172.16.0.2 "echo 'written without sync' > /workspace/nosync.txt"
sudo kill -9 $FC_PID   # SIGKILL — exactly what an aborted/timed-out Exec's teardown does (§4.1)
```

Reattach the same drive image to a fresh Firecracker process and check:

```bash
API_SOCKET=/tmp/fc4b.socket
sudo rm -f "$API_SOCKET"
sudo ./firecracker --api-sock "$API_SOCKET" < /dev/null > fc4b.log 2>&1 &
FC_PID=$!
sleep 0.3
curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data "$2" "http://localhost$1"; }
curl_put /machine-config '{"vcpu_count":2,"mem_size_mib":256,"smt":false}'
curl_put /boot-source "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}"
curl_put /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS\",\"is_root_device\":true,\"is_read_only\":false}"
curl_put /drives/workspace "{\"drive_id\":\"workspace\",\"path_on_host\":\"$PWD/workspace.img\",\"is_root_device\":false,\"is_read_only\":false}"
curl_put /network-interfaces/net1 '{"iface_id":"net1","guest_mac":"06:00:AC:10:00:02","host_dev_name":"tap0"}'
curl_put /actions '{"action_type":"InstanceStart"}'
sleep 2
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@172.16.0.2 "ip route add default via 172.16.0.1 dev eth0; mkdir -p /workspace; mount /dev/vdb /workspace; cat /workspace/nosync.txt 2>&1 || echo 'FILE MISSING OR EMPTY'"
```

The validation run's actual result: `cat: /workspace/nosync.txt: No such file or directory` — the
file wasn't truncated or corrupted, it simply never reached the block device at all. Don't expect
that _exact_ outcome every time (timing-dependent — occasionally the write does land before the
kill), but expect **no guarantee either way**. That's the property `sync` exists to fix.

### 9b. With sync — the same kill, now safe

```bash
ssh -i "$SSH_KEY" root@172.16.0.2 "echo 'written WITH sync' > /workspace/synced.txt && sync"
sudo kill -9 $FC_PID
```

Reattach again (same pattern as above), and:

```bash
ssh -i "$SSH_KEY" root@172.16.0.2 "cat /workspace/synced.txt"   # "written WITH sync" — every time
```

**Cleanup**:

```bash
sudo pkill -9 -f 'api-sock /tmp/fc4'
rm -f /tmp/fc4.socket /tmp/fc4b.socket workspace.img
```

**Maps to spec**: §4.3's Firecracker-arm row — _"guest page cache dies with the VM → `sync` is
mandatory and on the hot path"_ — and §8's "Write durability" correctness gate, which is this exact
experiment automated.

---

## 10. Page-cache sharing across VMs — why PSS, not RSS

Spec §7.3's sharpest trap: _"summing RSS across 200 processes multiplies the shared set by 200...
reporting ~50 GiB where the truth is ~2 GiB."_ This loads the **same** snapshot memory file into
three separate Firecracker processes and shows the arithmetic directly.

Take a **headless** snapshot for this one (no network interface). This matters, not just for
simplicity: three processes can each open the rootfs drive file concurrently just fine (regular
files don't enforce exclusivity), but a TAP device can only be attached to one process at a time —
loading three VMs from a networked snapshot concurrently fails two of them with
`Open tap device failed: ... Resource busy`, confirmed on the validation run.

```bash
API_SOCKET=/tmp/fc10.socket
sudo rm -f "$API_SOCKET"
sudo ./firecracker --api-sock "$API_SOCKET" < /dev/null > fc10.log 2>&1 &
FC_PID=$!
sleep 0.3
curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data "$2" "http://localhost$1"; }
curl_put /machine-config '{"vcpu_count":2,"mem_size_mib":256,"smt":false}'
curl_put /boot-source "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}"
curl_put /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS\",\"is_root_device\":true,\"is_read_only\":false}"
curl_put /actions '{"action_type":"InstanceStart"}'
sleep 1

sudo curl --unix-socket "$API_SOCKET" -s -S -X PATCH http://localhost/vm -d '{"state":"Paused"}'
sudo curl --unix-socket "$API_SOCKET" -s -S -X PUT http://localhost/snapshot/create -d "{
    \"snapshot_type\": \"Full\", \"snapshot_path\": \"$PWD/snap10.state\", \"mem_file_path\": \"$PWD/snap10.mem\"
}"
sudo pkill -9 -f "api-sock $API_SOCKET"
sudo chown $(id -u):$(id -g) "$PWD"/snap10.*
```

`vmtouch -dl` the memory file (see §2 for building `vmtouch` on AL2023), then load it into three
processes. Use `fuser` on each socket to get the **real** Firecracker PID rather than trusting `$!`
— `sudo` execs in place on both distros tested so `$!` happened to be correct throughout this note,
but `fuser` is the thing to reach for if that ever isn't true on your setup:

```bash
sudo vmtouch -dl "$PWD/snap10.mem" > vmtouch.log 2>&1 &
sleep 0.5
sudo vmtouch -v "$PWD/snap10.mem" | tail -5   # confirm 100% resident, locked

for i in 1 2 3; do
  sudo rm -f /tmp/pss-$i.socket
  sudo ./firecracker --api-sock /tmp/pss-$i.socket < /dev/null > pss-$i.log 2>&1 &
done
sleep 0.5

PID1=$(sudo fuser /tmp/pss-1.socket 2>/dev/null | awk '{print $1}')
PID2=$(sudo fuser /tmp/pss-2.socket 2>/dev/null | awk '{print $1}')
PID3=$(sudo fuser /tmp/pss-3.socket 2>/dev/null | awk '{print $1}')

for i in 1 2 3; do
  sock=/tmp/pss-$i.socket
  sudo curl --unix-socket "$sock" -s -S -X PUT http://localhost/snapshot/load -d "{
      \"snapshot_path\": \"$PWD/snap10.state\",
      \"mem_backend\": {\"backend_path\": \"$PWD/snap10.mem\", \"backend_type\": \"File\"},
      \"resume_vm\": false
  }"
done

echo "=== RSS per process ==="; for p in $PID1 $PID2 $PID3; do sudo grep VmRSS /proc/$p/status; done
echo "=== Pss per process ==="; for p in $PID1 $PID2 $PID3; do sudo grep Pss: /proc/$p/smaps_rollup; done
```

**A real caveat the first draft of this note got wrong**: with `resume_vm: false`, the guest's
vCPUs never run, so the guest never actually _touches_ its own RAM — a `MAP_PRIVATE` mapping is
lazy, and nothing faults those pages into any process's page tables. On the validation run each
process showed **~5 MB** of RSS, not the naive "~256 MB per VM" a reader might expect — that 5 MB
is Firecracker's own device-model bookkeeping, not guest memory. The ratio is still the whole
point, and it still held: summed across three processes, RSS came to **~15.4 MB** and Pss to
**~5.6 MB** — RSS roughly triples what Pss correctly counts once, because Pss divides shared pages
by their sharing count and RSS doesn't. Scale the guest RAM up and resume the VMs for real to see
this at the hundreds-of-MB scale the spec's own numbers are pitched at — but if you do, **don't**
point more than one resumed VM at the same read-write rootfs image. That's exactly the
"D > 1 standbys" hazard spec §4.3 calls out for a real shared block device: two live guest kernels
mounting one ext4 filesystem read-write will corrupt it. Give each resumed VM its own copy of the
rootfs file (or mount it read-only) if you extend this experiment.

**Cleanup**:

```bash
sudo kill -9 $PID1 $PID2 $PID3 2>/dev/null
sudo pkill vmtouch 2>/dev/null
sudo rm -f /tmp/pss-*.socket
```

**Maps to spec**: §7.3's "Use PSS, not RSS" callout and the `vmtouch -dl` mechanism from §2.4.

---

## 11. A rough, informal preview of E10's lifecycle numbers

**This is not E10.** §7.5 lists exactly the traps a real driver must control for (closed-loop
bias, page-cache asymmetry between arms, guest-clock garbage, thermal drift, warmup vs. steady
state) that a five-line `time` loop does not. Treat everything here as "which order of magnitude am
I in," not a number worth writing down — and remember `sudo`, per Gotcha 2, or `time` will report
how fast `curl` fails to connect, not how fast Firecracker does anything.

Boot a fresh, networked VM the same way as §4/§6, then time three things: the cold boot itself, a
restore of a snapshot taken from it, and a resume of that already-restored (still paused) VM.

```bash
API_SOCKET=/tmp/fc11.socket
sudo rm -f "$API_SOCKET"
sudo ./firecracker --api-sock "$API_SOCKET" < /dev/null > fc11.log 2>&1 &
FC_PID=$!
sleep 0.3
curl_put() { sudo curl -s -S -o /dev/null -w '%{http_code}\n' -X PUT --unix-socket "$API_SOCKET" \
    -H 'Content-Type: application/json' --data "$2" "http://localhost$1"; }
curl_put /machine-config '{"vcpu_count":2,"mem_size_mib":256,"smt":false}'
curl_put /boot-source "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}"
curl_put /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ROOTFS\",\"is_root_device\":true,\"is_read_only\":false}"
curl_put /network-interfaces/net1 '{"iface_id":"net1","guest_mac":"06:00:AC:10:00:02","host_dev_name":"tap0"}'

# cold boot, illustrative only: time from InstanceStart returning to sshd answering
time (
  sudo curl --unix-socket "$API_SOCKET" -s -S -X PUT http://localhost/actions -d '{"action_type":"InstanceStart"}' >/dev/null
  until ssh -i "$SSH_KEY" -o ConnectTimeout=1 -o StrictHostKeyChecking=no root@172.16.0.2 true 2>/dev/null; do sleep 0.05; done
)
```

Snapshot it, kill it, then restore into a fresh process and time both the restore and the resume:

```bash
sudo curl --unix-socket "$API_SOCKET" -s -S -X PATCH http://localhost/vm -d '{"state":"Paused"}'
sudo curl --unix-socket "$API_SOCKET" -s -S -X PUT http://localhost/snapshot/create -d "{
    \"snapshot_type\": \"Full\", \"snapshot_path\": \"$PWD/snap11.state\", \"mem_file_path\": \"$PWD/snap11.mem\"
}"
sudo pkill -9 -f "api-sock $API_SOCKET"

sudo rm -f /tmp/fc11b.socket
sudo ./firecracker --api-sock /tmp/fc11b.socket < /dev/null > fc11b.log 2>&1 &
sleep 0.3

# restore-from-snapshot, paused (no vCPU resume yet)
time sudo curl --unix-socket /tmp/fc11b.socket -s -S -X PUT http://localhost/snapshot/load -d "{
    \"snapshot_path\": \"$PWD/snap11.state\",
    \"mem_backend\": {\"backend_path\": \"$PWD/snap11.mem\", \"backend_type\": \"File\"},
    \"resume_vm\": false
}" >/dev/null

# resume-from-paused (already restored — this is the "acquire a standby" cost, §3.2's target)
time sudo curl --unix-socket /tmp/fc11b.socket -s -S -X PATCH http://localhost/vm -d '{"state":"Resumed"}' >/dev/null
```

On the validation run (a shared/nested-virt AWS instance, **not** metal — treat these as an order
of magnitude, not a benchmark): cold boot to sshd answering took **~1.9s**; restoring a paused
snapshot into a fresh process took **~37ms**; resuming an already-restored, still-paused VM took
**~17ms**. The direction is the one §3.2 predicts — cold boot ≫ restore > resume-from-paused — and
that directional relationship is the thing worth checking on your own box, not the absolute
numbers.

If "resume-from-paused" isn't dramatically cheaper than "restore-from-snapshot" on your box, that's
worth noticing but not worth trusting — you're very likely on a nested-virt laptop/VM, not metal,
and §7.2 explicitly separates nested from metal results for exactly this reason ("nested fires no
stop rule... metal is authoritative").

**Cleanup**:

```bash
sudo pkill -9 -f 'api-sock /tmp/fc11'
rm -f /tmp/fc11.socket /tmp/fc11b.socket
```

**Maps to spec**: §7.2's E10 rungs 2–3 (warm hot path, replenishment unit cost) — this is the
five-minute sanity check before building the real driver, not a substitute for it.

---

## What this tutorial deliberately skips

- **Cloud Hypervisor / virtio-fs.** Spec §9 already flags CH as the unverified arm; §10's build
  order puts "verify CH's snapshot caveats" as a reading exercise (step 0), not a hands-on one.
- **A real guest agent.** §5's vsock section is `socat`, not a framed protocol — the actual
  `guestagent` package is the implementation, not something to prototype here.
- **Networking beyond what's needed to reach a guest for typing commands.** P4's `Exec` path is
  vsock-only; TAP/NAT here exists purely so SSH works for these experiments (and §10 deliberately
  boots headless to sidestep the TAP-device exclusivity issue when loading concurrently).
- **Anything resembling `vmpool`'s state machines** (§4.2) — standby depth, replenishment delay,
  idle sweeps. Those need the real package; this tutorial only exercises the primitives it's built
  from.
