# microVM sandbox: experiments and correctness gates

## Correctness gates (spec §8)

Spec §8: "none of these produces a number, and all are blocking." This section is
recorded first, before any performance rung, so a number is never read without its
caveat.

Ten gates plus the static privilege pin. `gates_kvm_test.go` implements all ten;
`gates_privilege_test.go` implements the privilege pin (needs no KVM, already existed).
Four of the ten gates exercise the Pool's own bookkeeping against the **fake**
launcher/clock (`internal/vmpool`'s existing test double) and need no KVM, and were
run and verified directly by this task (mutation evidence below). The remaining six
(plus the `real_launcher` half of `TestGateNoVMReuse`) require `/dev/kvm` and a built
golden snapshot. That 4/6 split is about **which gates need KVM**, not about which
passed — do not read it as a tally; the pass/fail counts are stated and explained
below. This task's own environment is a darwin workstation with neither, so
they were run on the rig across the fix rounds below, each round fixing exactly what
the previous rig run found broken. **Both arms have now actually been run on real
hardware against real KVM and a real golden snapshot** — the final round below is the
last of these runs, and its numbers are the ones that stand.

**Measured result, final round: Firecracker 10/10 PASS. Cloud Hypervisor 3/10 PASS,
7 FAIL — a documented stopping point, not a bug still being chased.** No gate was
weakened, skipped, or reinterpreted to produce either number: every PASS ran to
completion against real KVM and a real golden snapshot, and every FAIL is a real,
reproduced failure with a known signature (see "Final round" below). That sentence is
the reason the rest of this section can be trusted.

**How the tally is counted, so the arithmetic is checkable rather than reconstructed:
a gate with ANY failing subtest counts as FAILED.** There are ten gates and the table
below has eleven rows, because `TestGateNoVMReuse`'s two subtests are listed
separately; the gate is scored once, on its worse half. Every Cloud Hypervisor number
in this document is `3/10 PASS, 7 FAIL` on that rule. **This was previously recorded
as `4/10 PASS, 6 FAIL`, which was wrong twice over:** it scored
`TestGateNoVMReuse` a PASS for its `fake_launcher_concurrency` subtest while its
`real_launcher` subtest is a documented FAIL, and 4 + 7 named failures does not
reconcile to ten gates at all. Corrected per the final whole-branch review's L1. The
underlying rig results are unchanged — no gate's outcome moved, only the sum — and the
error originated in this task's own dispatch, not in the rig run. Rounding a
half-failed gate up to a pass is a mild instance of exactly the thing the paragraph
above disclaims, which is why the rule is now stated instead of implied.

| Gate                                                             | Firecracker (final round)                             | Cloud Hypervisor (final round)                       |
| ---------------------------------------------------------------- | ----------------------------------------------------- | ---------------------------------------------------- |
| `TestGateEmptyKeyIsRefused`                                      | PASS (0.00s)                                          | PASS                                                 |
| `TestGateNoVMReuse` (`fake_launcher_concurrency` subtest)        | PASS (0.75s, both subtests)                           | PASS (subtest only — gate scores **FAIL**, next row) |
| `TestGateNoVMReuse` (`real_launcher` subtest)                    | PASS (0.75s, both subtests)                           | **FAIL** — 30s timeout in `Restore`                  |
| `TestGateWriteDurability`                                        | PASS (0.57s)                                          | **FAIL** — 30s timeout in `Restore`                  |
| `TestGateNoCrossRunBleed`                                        | PASS (1.26s)                                          | **FAIL** — 30s timeout in `Restore`                  |
| `TestGateSnapshotHoldsNoSecrets`                                 | PASS (0.41s)                                          | **FAIL** — 30s timeout in `Restore`                  |
| `TestGateLeakFreeTeardown`                                       | PASS (5.04s)                                          | **FAIL** — 30s timeout in `Restore`                  |
| `TestGateParkedThenResumed`                                      | PASS (0.00s)                                          | PASS                                                 |
| `TestGateReclaimThenRedispatch`                                  | PASS (0.00s)                                          | PASS                                                 |
| `TestGateClock`                                                  | PASS (0.28s) — **failed first, correctly**; see below | **FAIL** — 30s timeout in `Restore`                  |
| `TestGateOutputCapAtSource`                                      | PASS (0.31s)                                          | **FAIL** — 30s timeout in `Restore`                  |
| `TestNothingInTheWorkerPathSpawnsAShell` (privilege pin, static) | PASS                                                  | n/a (arm-independent)                                |
| `TestTheHostFakeCannotServeARealVMMConfig`                       | PASS                                                  | n/a (arm-independent)                                |

Firecracker: **10/10 on real hardware, with no environment overrides** — the suite
self-configures now (fix round 2's startup device checks, plus fix round 3's traversal
fix). Nine of the ten passed on the first properly-configured run; `TestGateClock`
failed _first_, correctly, catching a real, shipped defect — see "`TestGateClock`
caught a real defect on its merits" below, which this final round confirms as the gate
suite's headline result: a subtle bug that nothing but a correctness gate would ever
have found, caught before it could ship.

Cloud Hypervisor: **3/10 PASS** (`TestGateEmptyKeyIsRefused`,
`TestGateParkedThenResumed`, `TestGateReclaimThenRedispatch` — none of which reach a
real `Restore()` against a live guest), **7 FAIL** (`TestGateWriteDurability`,
`TestGateNoCrossRunBleed`, `TestGateNoVMReuse`, `TestGateSnapshotHoldsNoSecrets`,
`TestGateLeakFreeTeardown`, `TestGateClock`, `TestGateOutputCapAtSource` — every gate
that actually restores a paused VM and runs a command in it). `TestGateNoVMReuse` is
counted as a FAIL: its `fake_launcher_concurrency` subtest passes but its
`real_launcher` subtest does not, and per the counting rule stated above a gate with
any failing subtest counts as failed. Its stated assertion is that "the
`workspace_key` assertion holds under concurrency" against a real VMM, and on Cloud
Hypervisor it did not run to completion. See "Final round" below for the failure
signature and the decision this project has made about it.

### Rig command for the six KVM-only gates (both arms)

Four operational preconditions, all found the hard way — each one cost a rig cycle
to diagnose before it was understood, so they are recorded here explicitly rather
than left implicit in the command below:

1. **The suite must run as root.** `/proc/sys/fs/protected_hardlinks` is `1` and the
   golden snapshot's files are root-owned `0444`, so an unprivileged process cannot
   hardlink them into a jail; the jailer itself also needs root to chroot and to
   bind-mount `/dev/kvm`. Without `sudo`, every Firecracker gate fails EPERM. (The
   command below previously omitted `sudo` — that was a bug in this document, not in
   the gates.)
2. **`sudo` resets the environment.** `PATH` must explicitly include `/sbin` and
   `/usr/sbin` — `mkfs.ext4` lives there, and the launcher shells out to it to build
   each VM's workspace image — and every `SH_*` variable must be passed on the `sudo`
   command line itself rather than relying on `sudo -E`, which does not reliably
   survive a hardened `sudoers` policy.
3. **`SnapshotDir`, `WorkspaceRoot`, and the chroot/run-dir base must all share one
   filesystem device.** `Restore()` hardlinks the golden snapshot's components (and,
   for Firecracker, the per-run workspace image) across these paths, and `hardlink(2)`
   cannot cross devices — see "Fix round 1" and "Fix round 2" below for exactly how
   this was found and fixed. `pool.New` now fails fast, by name, if this is violated
   (fix round 2's `checkDeviceSharing`), so a misconfigured rig gets a clear startup
   error instead of a confusing `EXDEV` three Execs deep.

```bash
for vmm in firecracker cloud-hypervisor; do
  echo "== $vmm"
  sudo env "PATH=/usr/sbin:/sbin:$PATH" \
    SH_KVM=1 SH_VMM=$vmm SH_SNAPSHOT_IMAGE_DIR=/srv/snapshots/swebench-py311 \
    go test ./internal/vmpool/ -run TestGate -v -timeout 30m
done
```

**Measured, not merely expected** (see the results table above and "Final round"
below): Firecracker is green end-to-end, 10/10. Cloud Hypervisor reaches 3/10, with
the remaining 7 failing at `Restore()` for reasons this project has decided are a
documented stopping point, not something this command will fix by being run again.

### Fix round 1: chroot base / run dir must share a device with the snapshot

The first real rig run of the six KVM-only gates failed every Firecracker gate at
`Restore()`:

```
firecracker: restore vm-1: hardlink vmstate:
link /srv/snapshots/.../vmstate /tmp/TestGate.../root/vmstate: invalid cross-device link
```

Cause: `fcLauncher` (`launcher_firecracker_test.go`) set `ChrootBase: t.TempDir()`.
`t.TempDir()` honours `$TMPDIR`; on the rig `/tmp` is tmpfs while the golden snapshot
lives on `/srv` (ext4) — a different device. The jailer **hardlinks** (never copies)
every snapshot component into `ChrootBase/<id>/root/`, deliberately, so that N standby
VMs sharing one golden snapshot don't each duplicate a multi-hundred-MiB memfile. A
hardlink across devices is EXDEV, unconditionally, so this failed on every restore
regardless of permissions.

Fix: added `sameDeviceSiblingDir(t, snapshotDir)` to
`remote-worker/internal/vmpool/launcher_firecracker_test.go`, mirroring
`new_verify_dir()` in `build-snapshot.sh` (a `mktemp -d` sibling of the snapshot
directory's parent, on the same filesystem by construction, itself the fix for the
identical problem in the shell harness's own verify jail, commit `4059338`). It does
**not** `os.MkdirAll` the parent into existence — like `new_verify_dir()`'s `mktemp -d`,
a missing parent (e.g. `/srv/snapshots` itself absent) is a real misconfiguration and
should fail loudly rather than silently create a directory tree nobody asked for. An
`SH_CHROOT_BASE` env var overrides the parent outright for a rig with an unusual layout;
absent that, the default is now correct without the operator knowing anything. Cleanup
is via `t.Cleanup`, which — like `t.TempDir()`'s own guarantee — runs even on a failing
test, so a gate that fails partway through does not leak a jail (each holds a
hardlinked ~256 MiB memfile plus a workspace image; on a rig with a 31 GiB disk that
adds up fast across repeated runs).

`fcLauncher` is only ever called after `requireKVM(t)` at every call site in the
codebase, so this helper is never invoked — and never touches the filesystem, and never
requires `SnapshotDir` to exist — when `SH_KVM` is unset. The non-KVM path is therefore
unaffected by construction, not just by testing; the full non-KVM suite
(`go test ./internal/vmpool/... -race -count=1`) was re-run after this change and stays
green (4 gates PASS, the rest SKIP, 0 FAIL).

Cloud Hypervisor's `Restore()` (`launcher_chv.go`) has the structurally identical
exposure: it also hardlinks (`os.Link`) the golden `vmstate`/`memory-ranges` files from
`SnapshotDir` into `RunDir/<id>/`. `chvOpts(t)` (`launcher_chv_test.go`) set
`RunDir: t.TempDir()` — the same bug, just never exercised on the rig yet because the
reported run only covered the Firecracker arm. Fixed it the same way:
`RunDir: sameDeviceSiblingDir(t, snapshotDir)`, reusing the identical helper. This is
beyond the single item flagged in the fix-round request, done because the fix was
already written, generic, and the alternative was knowingly leaving an identical
landmine in the other arm.

**New test:** `TestSameDeviceSiblingDirSharesDeviceWithTarget`
(`launcher_firecracker_test.go`) is the assertion that would have caught the original
bug without any hypervisor — it stats `sameDeviceSiblingDir`'s output and the
snapshot directory's parent (`syscall.Stat_t.Dev`) and asserts they match. It stands in
a `t.TempDir()` for the snapshot directory rather than requiring the real
`SH_SNAPSHOT_IMAGE_DIR` to exist, so it runs everywhere the fake-substrate gates run.

**Mutation-test result — honest non-reproduction on this machine:** the intended
mutation is to point the assertion's "got" directory at a hardcoded `/tmp` instead of
`sameDeviceSiblingDir`'s real output, and confirm the assertion fails on a host where
`/tmp` is a separate filesystem from the snapshot directory. On this task's own darwin
development machine, `stat -f` shows `/tmp`, `$TMPDIR`, `/var/tmp`, and the repo's own
working directory all report the **same** device number (`16777234` — macOS mounts one
APFS volume for all of these under normal configuration). Applying the mutation
(`got := "/tmp"` in place of the `sameDeviceSiblingDir` call) left the test PASSing, not
failing, confirming this machine cannot exhibit the failure the assertion exists to
catch. The mutation was reverted immediately after (`git diff --stat` confirmed clean),
and the test re-run to confirm PASS on the real code path. This is exactly the situation
flagged as worth reporting honestly rather than claiming a green mutation result that
would not reproduce: on the rig, where `/tmp` is tmpfs and `/srv` is a separate ext4
device, this same mutation would be expected to fail the assertion — but that has not
been verified by this agent on real rig hardware, only reasoned from the `df`-visible
device split the coordinator's own bug report already demonstrated.

### `TestGateClock` caught a real defect on its merits

The rig's first run of `TestGateClock` failed — correctly. It caught a `clockOK`
one-shot latch in the guest agent that had been baked into the golden snapshot's own
memory image: every VM restored from that snapshot believed its clock had already been
corrected, because the snapshot was taken _after_ the guest agent's real boot-time clock
fix had already run once and set the latch. Fixed upstream in `66fdf86` (remove the
latch entirely — restoring a paused VM's clock correction must not depend on in-memory
state captured before the snapshot, since that state is exactly what gets replayed
unconditionally on every restore). This is precisely the class of defect spec §8's gates
exist to find and a launcher-level test never would have: it is a property of the
golden snapshot's captured memory, not of the launcher or the pool.

### Mutation-test evidence for the four gates that ran directly under this task

Each of the four fake-substrate gates above was verified by breaking the exact
production code path it exists to catch, observing the gate FAIL with a specific
message, reverting the change (`git diff --stat` confirmed clean on the mutated file
each time), and observing the gate PASS again:

- **`TestGateNoVMReuse`** — mutated `pool.go`'s `destroy()` to append the
  about-to-be-destroyed VM back onto the run's standby pool and skip the real
  `vm.Destroy()` call (simulating a "recycle the handle instead of destroying it"
  regression). Observed failure: `concurrent Exec: spawn-failure: resume "run-a":
fakeVM vm-3: Resume twice`. Reverted; gate passed again.
- **`TestGateEmptyKeyIsRefused`** — mutated `workspace.go`'s `checkKey` to skip the
  empty-key check. Observed failure: `ReasonOf(err) = invalid-workspace-key, want
empty-workspace-key` (the empty string fell through to the regex check instead of
  being refused for being empty). Reverted; gate passed again.
- **`TestGateParkedThenResumed`** — mutated `sweep.go`'s `sweepOnce` so the
  `WorkspaceIdle` branch (drop the workspace) fires at `StandbyIdle` too instead of
  only parking. Observed failure: `ColdAcquires[ColdParked] rose by 0, want 1 — a
parked-then-resumed run must be a cold acquire` (the run's map entry was deleted
  outright, so the next Exec was classified as a first-exec cold acquire, not a
  parked one). Reverted; gate passed again.
- **`TestGateReclaimThenRedispatch`** — mutated `pool.go`'s `Reclaim` to skip its
  final `removeWorkspace(dir)` call. Observed failure: `workspace .../gate-reclaim
survived Reclaim: err=<nil>`. Reverted; gate passed again.

### Resolved: cloud-hypervisor snapshot naming mismatch

This section originally documented a blocker found while writing the gates:
`launcher_chv.go`'s `Restore()` expected the golden snapshot's cloud-hypervisor-native
filenames (`config.json`, `memory-ranges`, `state.json`) directly under `SnapshotDir`,
but `build-snapshot.sh` ships it under the unified names (`vmstate`, `memfile`,
`ch-config.json`) shared with the Firecracker arm, with no rename in between — every
cloud-hypervisor-arm restore was expected to fail with "no such file," not because any
gate's property was false, but because the two pieces disagreed on a filename
convention.

**Fixed in `00f7c11`** ("translate golden snapshot names to CH-native names in
Restore"), which landed after this task's initial commit and before fix round 1.
**Update, final round:** this fix has since been confirmed against real
cloud-hypervisor hardware — the naming mismatch it fixed is not among the failure
signatures in the CH arm's 3/10 result below, and CH now gets as far as
`Restore()` reading its own files correctly and reaching device restoration before
failing, which would not happen if this naming bug were still present. It is
genuinely resolved, not merely resolved-on-paper; what remains is a different,
later-stage problem — see "Final round" below.

### Fix round 2: WorkspaceRoot's own device coupling, a startup check for the constraint, and a `go vet` gap

Fix round 1 fixed one device coupling per arm (Firecracker's `ChrootBase`, CHV's
`RunDir`) against the golden snapshot's `SnapshotDir`. It missed that Firecracker
has a **second, independent** coupling: `Restore()` hardlinks the per-run
`workspace.img` from `Config.WorkspaceRoot` into the jail root alongside the
golden snapshot's own files, so `WorkspaceRoot` must ALSO share a device with
`SnapshotDir`/`ChrootBase` — a three-way constraint, not two separate two-way
ones. Cloud Hypervisor has no such second coupling: its `Restore()` never
hardlinks the workspace at all — virtiofsd shares `WorkspaceRoot` with the guest
live over virtio-fs — so CHV's constraint stays two-way (`SnapshotDir` ↔
`RunDir`) and must NOT be tightened to include `WorkspaceRoot`.

**Item 1 — `poolFor`'s `WorkspaceRoot: t.TempDir()`.** Same bug shape as fix
round 1, on the third leg: `gates_kvm_test.go`'s `poolFor` and
`TestGateLeakFreeTeardown` built their `Config` with a bare `t.TempDir()` for
`WorkspaceRoot`, which — like `ChrootBase` before it — only worked by accident on
a single-device host. Fixed by routing it through the same
`sameDeviceSiblingDir(t, snapshotDir)` helper fix round 1 introduced, keyed to
the identical `snapshotDir` value the arm's own launcher (`fcLauncher`) uses, so
all three paths land on one device together rather than being fixed pairwise.
Harmless for the Cloud Hypervisor arm: its `checkDeviceSharing` (below) never
inspects `WorkspaceRoot`, so sharing a device with the snapshot costs that arm
nothing and constrains nothing extra.

**Mutation test — honest non-reproduction, same shape as fix round 1's.**
Reverted `poolFor`'s fix back to a bare `t.TempDir()` (keeping the file
compiling by discarding the now-unused `snapshotDir` local) and re-ran the full
suite. Result: 0 FAIL. Every gate that exercises `poolFor` (`TestGateWriteDurability`,
`TestGateNoCrossRunBleed`, `TestGateLeakFreeTeardown`, etc.) reported `SKIP`, not
PASS or FAIL — `requireKVM(t)` skips before the mutated code path is ever
reached, because this machine has no `/dev/kvm` and `SH_KVM` is unset. This is
the expected, anticipated outcome for a gate-level mutation on this machine, not
a gap in the fix: the same mutation on the rig (real KVM, real two-device
layout) would be expected to fail every gate above with the same
`invalid cross-device link` signature fix round 1's bug report showed for
`ChrootBase`, because the underlying hardlink call is unconditional in
`Restore()`. Reverted immediately after observing this; the file is back to its
fixed state and the full suite is green again (see Verification below).

**Item 2 — validate the constraint at startup, not just in test helpers.** The
workspace hardlink is deliberate and load-bearing — it is what makes
`TestGateWriteDurability` a meaningful property rather than a coincidence — so
an operator who puts `WorkspaceRoot`, `SnapshotDir`, and the jail/run directory
on three individually-reasonable filesystems is hitting a real deployment
constraint, not a test-fixture bug, and deserves a startup failure that names
exactly what to move, not an EXDEV three Execs deep that reads like a launcher
defect.

Added:

- `remote-worker/internal/vmpool/devicecheck.go` — `checkPathsShareDevice(why
string, paths ...namedPath) error`, the shared comparison-plus-formatting
  logic; `namedPath{name, path}` pairs a host path with the Config/Options field
  it should be reported under, so the error names something an operator can
  actually go edit, not just a bare directory string. `deviceRequirer` is a
  package-internal interface (`checkDeviceSharing(cfg Config) error`) that only
  `firecrackerLauncher` and `chvLauncher` implement — `FakeLauncher` hardlinks
  nothing and deliberately does not implement it.
- `firecrackerLauncher.checkDeviceSharing` (`launcher_firecracker.go`) — the
  three-way check: `FirecrackerOptions.SnapshotDir`, `Config.WorkspaceRoot`,
  `FirecrackerOptions.ChrootBase`.
- `chvLauncher.checkDeviceSharing` (`launcher_chv.go`) — the two-way check:
  `CHVOptions.SnapshotDir`, `CHVOptions.RunDir`. Deliberately excludes
  `Config.WorkspaceRoot` — see the scope distinction above.
- `pool.New` (`pool.go`) type-asserts `lc` against `deviceRequirer` right after
  the existing `lc.Kind() != cfg.VMM` cross-check, and fails construction if
  `checkDeviceSharing` errors. Placed there, not in each launcher's constructor
  or in `Restore()` itself, because `New` is the one place a `Config` (which
  owns `WorkspaceRoot`) and a constructed `Launcher` (which owns
  `SnapshotDir`/`ChrootBase`/`RunDir`) are always both in scope at once — the
  same "fail the unit at start" reasoning spec §6 already applies to the
  KVM-unavailable check in `Probe`. Every real deployment path
  (`cmd/microvm-worker/main.go`) and every gate (`poolFor`,
  `TestGateLeakFreeTeardown`) constructs its pool via `New`, so nothing that
  skips this check exists.

The failure message names every path, the Config/Options field it came from,
its device number, and a one-sentence why, e.g.:

```
vmpool: FirecrackerOptions.SnapshotDir, Config.WorkspaceRoot, FirecrackerOptions.ChrootBase
must all be on the same filesystem device, but are not:
FirecrackerOptions.SnapshotDir=/snap (device 1); Config.WorkspaceRoot=/work (device 1);
FirecrackerOptions.ChrootBase=/jail (device 2). Restore hardlinks the golden snapshot's
components and the per-run workspace image into the jail, and hardlink(2) cannot cross devices
```

**Testing a real device mismatch on a single-device machine.** This darwin
development machine has exactly one filesystem device across `/`, `/tmp`,
`$TMPDIR`, `/var/tmp`, and the repo's own working directory (confirmed by both
this round and fix round 1's identical finding), so no pair of real directories
on it can ever exercise the mismatch branch. Rather than leave this untested
locally, `devicecheck.go` added a package-level seam,
`var deviceNumberFunc = deviceNumber` (mirroring the existing `Clock`/
`RealClock()` seam this package already uses for exactly the same reason: real
production code always calls through the real function, but a test can swap it
for a fake one). `devicecheck_test.go` (new) uses this seam to fake two or three
distinct device numbers and drive both `checkPathsShareDevice` directly and both
launchers' `checkDeviceSharing` through it, including the coordinator's literal
ask — construct a config whose paths differ by device and assert the failure
message names all of them (`TestFirecrackerCheckDeviceSharingNamesAllThreePaths`).
8 new tests, all passing:

- `TestCheckPathsShareDeviceAllowsMatch` / `...DetectsMismatch`
- `TestFirecrackerCheckDeviceSharingNamesAllThreePaths` /
  `...AllowsOneSharedDevice`
- `TestCHVCheckDeviceSharingIgnoresWorkspaceRoot` (pins the scope distinction:
  `WorkspaceRoot` on a third fake device must NOT fail CHV's check) /
  `...DetectsMismatch`
- `TestNewPropagatesDeviceSharingFailure` / `...SucceedsWhenDeviceSharingPasses`
  (pool.New's wiring itself, via a small `deviceCheckLauncher` test double with
  a controllable `checkDeviceSharing`, since `FakeLauncher` deliberately does
  not implement `deviceRequirer`)

**Mutation-test evidence for Item 2 (fully reproducible locally, via the seam):**

- Changed `checkPathsShareDevice`'s `mismatch = true` to `mismatch = false`
  (simulating "the comparison loop stops detecting a mismatch"). Observed
  failure: exactly `TestCheckPathsShareDeviceDetectsMismatch`,
  `TestFirecrackerCheckDeviceSharingNamesAllThreePaths`, and
  `TestCHVCheckDeviceSharingDetectsMismatch` FAILed — the three tests that
  construct a genuine mismatch — with every other test (including the
  allow-match tests) still passing. Reverted; suite green again.
- Changed `pool.New`'s `if dr, ok := lc.(deviceRequirer); ok { ... }` block to
  discard `dr` without calling `checkDeviceSharing` (simulating "the check is
  wired up but never invoked"). Observed failure: exactly
  `TestNewPropagatesDeviceSharingFailure` FAILed (a launcher whose
  `checkDeviceSharing` always errors no longer blocked `New`); every other test,
  including `TestNewSucceedsWhenDeviceSharingPasses`, stayed green. Reverted;
  suite green again.

Both cycles: mutate, run the full `internal/vmpool` suite, confirm the expected
and only the expected tests fail, revert from a saved copy, rebuild and re-test
to confirm clean.

**Item 3 — `GOOS=windows go vet` failure, and the verification gap it exposed.**
`launcher_firecracker_test.go`'s own `deviceOf` test helper kept a second,
test-only `syscall.Stat_t.Dev` lookup, duplicating what `device_unix.go` (added
this round) already does for production code. `syscall.Stat_t` does not exist on
`GOOS=windows`, so `GOOS=windows go vet ./...` failed:
`launcher_firecracker_test.go:90:33: undefined: syscall.Stat_t`. `go build
./...` never caught this — **build does not compile `_test.go` files at all**,
only `vet` (and `test`) do, so a `GOOS=windows go build ./...`-only check is
structurally blind to this entire class of bug regardless of how carefully it
is run.

Fix: `deviceOf` now delegates to the production `deviceNumber` function
(`device_unix.go` under `//go:build unix`, `device_other.go` under
`//go:build !unix`, following the `cgroup_windows.go` precedent from Task 17)
instead of keeping its own `Stat_t` lookup, and skips (does not fail) on a
platform where `deviceNumber` cannot answer — `device_other.go`'s stub is a
documented "unsupported here," not a bug this test should report.

**This is fixed in the standard, not just patched once.** Verification for this
task, and every future round on this package, is now: `go build ./...` AND
`go vet ./...` for **all three** of `GOOS=linux`, `GOOS=darwin`, `GOOS=windows`
(six checks total), plus `go test ./... -count=1` for the whole `remote-worker`
module — not `go build` alone on one or two platforms, precisely because `vet`
catches compile errors in test files that `build` structurally cannot.

**Verification after fix round 2:** all six `go build`/`go vet` combinations
(`linux`/`darwin`/`windows` × `build`/`vet`) exit 0; `go test ./...` for the
whole `remote-worker` module exits 0 (all packages PASS or `[no test files]`,
0 FAIL); `internal/vmpool` alone shows the 8 new device-check tests plus every
pre-existing gate/unit test passing, KVM-gated gates SKIPping as expected on
this machine.

### Fix round 3: a root-owned 0700 ancestor blocks virtiofsd's own unprivileged traversal

The coordinator diagnosed this on the rig: a hardlink-jail sibling directory
`sameDeviceSiblingDir` (`launcher_firecracker_test.go`, fix round 1) creates via
`os.MkdirTemp` — mode `0700`, root-owned when the gates run as root — becomes an
**ancestor** of the per-run workspace directory both arms use. The Firecracker
arm never notices: `jailer`'s whole process tree runs as root too, and root
needs no permission bit to enter anywhere. The Cloud Hypervisor arm does notice:
virtiofsd drops privileges to `CHVOptions.VirtiofsdUID/GID` (an unprivileged
uid — `validate()` refuses `0`) before it ever touches the workspace, and the
kernel checks execute permission on **every** ancestor between `/` and that
workspace, not just the workspace's own (correctly chowned, by
`chvPrepareOwnership`) mode. A `0700` ancestor blocks that unprivileged
traversal exactly as effectively as a `0700` leaf would. virtiofsd does not
diagnose this itself: an `EACCES` on an ancestor, from virtiofsd's own side,
looks identical to the leaf "not existing" at all — which is exactly the
confusing message the coordinator saw for a directory plainly present on disk.

**Item 1 — `sameDeviceSiblingDir` now chmods its directory to `0711`, not the
default `0700`.** `0711` — execute-without-read, `rwx--x--x` — was the
coordinator's deliberate choice over `0755`: it lets an unprivileged process
traverse _through_ to a path it has been told the name of, without letting it
`readdir` what else lives in there, keeping this jail's other per-run contents
unlistable by anyone but its root owner — the standard "reachable but not
listable" posture. The fix carries an explicit comment warning against
"tightening" this back to `0700`: root needs no permission bit at all, so every
Firecracker gate would keep passing while every Cloud Hypervisor one silently
broke again — which is exactly how this bug reached the rig undetected in the
first place.

**Item 2 — a pre-flight reachability check in `chvLauncher.Restore`, before
virtiofsd is ever spawned.** `chvPrepareOwnership` (fix round 1) correctly
chowns `req.WorkspaceDir` itself, but its own doc comment says plainly it does
not reach the workspace's ancestors — those belong to whoever created
`WorkspaceDir` (the pool/orchestration layer, or, in the gates,
`sameDeviceSiblingDir`), not to this launcher. Authorized by the coordinator as
scope-crossing production-code fix ("the traversal rule spans the harness that
creates directories and the launcher that consumes them"), but explicitly
diagnostic-only — no self-healing: "a launcher silently chmod'ing directories it
did not create would be worse than the error it replaces."

Added:

- `remote-worker/internal/vmpool/traversalcheck.go` (new) —
  `checkPathTraversableBy(path string, uid, gid uint32) error` walks every
  ancestor of `path` from its immediate parent up to the filesystem root,
  confirming stat(2)'s permission bits grant execute to `uid:gid` at each level.
  `canTraverse` mirrors the kernel's own class-selection order: owner class if
  `uid` matches the ancestor's owning uid, else group class (primary group
  only — a documented simplification, not an oversight), else "other". The
  failure names the specific blocking ancestor's path, its mode, its owning
  uid:gid, and the uid:gid being checked — the coordinator's literal ask
  ("say so precisely: which path, which uid, and which ancestor's mode is
  blocking").
- `statOwnerMode` (`device_unix.go`/`device_other.go`) — a `//go:build
unix`/`!unix`-split stat helper returning a path's owning uid/gid/mode,
  alongside the existing `deviceNumber` from fix round 2's identical platform
  split, for the identical reason: `GOOS=windows go vet` compiles `_test.go`
  files and `syscall.Stat_t` does not exist there.
- `chvCheckWorkspaceReachable` (`launcher_chv.go`) — `checkPathTraversableBy`
  through a seam (mirroring `chvPrepareOwnership`'s own seam), wired into
  `Restore` immediately after `chvPrepareOwnership` and before virtiofsd is
  spawned. On failure, `Restore` aborts with the ancestor/mode/uid detail
  instead of letting virtiofsd hit the same `EACCES` from underneath and
  mis-report it as the leaf "does not exist."

**Fixing the tests, not just the code: a non-root test runner and macOS's own
`$TMPDIR`.** The first full run after writing this surfaced three failures, all
environment artifacts of the new tests' own setup, not bugs in the logic:

- `TestRestoreChecksWorkspaceReachableBeforeVirtiofsd` and
  `TestRestoreFailsWhenWorkspaceIsUnreachable` both let the real
  `chvPrepareOwnership` run ahead of the code under test, and its real
  `os.Chown(..., 65534, 65534)` fails with "operation not permitted" on this
  non-root darwin test runner — the same, already-documented limitation
  `TestRestorePreparesVirtiofsdOwnershipPropagatesFailure` carries. Fixed by
  stubbing `chvPrepareOwnership` to `return nil` in both tests, the same
  pattern `TestRestoreCallsPrepareOwnership` already uses.
- `TestCheckPathTraversableByAllowsWorldExecutableAncestors` failed because
  `t.TempDir()`'s own ancestry is not actually world-executable on this
  machine: `testing.T.TempDir()` creates two levels at default `0700`
  (a per-test root, then a per-call numbered subdirectory), and — after
  chmodding both to `0711` — the walk kept going and hit darwin's own
  `$TMPDIR` (`/var/folders/<hash>/<hash>/T`), itself `0700` and owned by the
  logged-in user, not this test. Chmodding a real, shared, system-owned
  directory just to pass a unit test would itself be the kind of self-healing
  Item 2 deliberately refuses to do to a caller's directories — so this test
  instead fakes `statOwnerModeFunc` for every ancestor above what it created
  and chmodded itself, exercising the real walk/logic for the part it
  controls and a synthetic "world-executable" answer for the host's own
  temp-directory layout above that.

**Mutation test, Item 1 — reproducible locally.** Reverted
`sameDeviceSiblingDir`'s `os.Chmod(dir, 0o711)` to `0o700` and re-ran
`TestSameDeviceSiblingDirIsTraversableButNotListable`. Observed failure:

```
sameDeviceSiblingDir(.../.gates-hardlink-jail-1439721737) mode = 0700, want 0711
(execute-without-read: traversable by an unprivileged virtiofsd, not listable by it)
```

Reverted; test passes again, full suite green.

**Mutation test, Item 2 — reproducible locally, two ways.**

- _Point the shared dir at an unreachable path_ (the coordinator's literal
  ask): `TestRestoreFailsWhenWorkspaceIsUnreachable` builds a genuine `0700`
  `blocker` directory (owned by this test's own uid, never
  `chvOpts`'s `VirtiofsdUID` 65534) as an ancestor of `WorkspaceDir`, then
  drives the real `lc.Restore(...)`. The resulting error names all three: the
  blocking ancestor's path (`blocker`), its mode (`0700`), and the checked uid
  (`65534`) — confirmed by both the standalone unit test
  (`TestCheckPathTraversableByDetectsBlockingAncestor`) and this end-to-end one
  passing, and by inspecting the assertions directly (both assert
  `strings.Contains` on all three).
- _Remove the check itself_: temporarily wrapped the `chvCheckWorkspaceReachable`
  call site in `Restore` in `if false { ... }` (simulating "call site
  deleted"), rebuilt, and re-ran the suite. Observed failure: exactly
  `TestRestoreChecksWorkspaceReachableBeforeVirtiofsd` and
  `TestRestoreFailsWhenWorkspaceIsUnreachable` FAILed —
  `TestRestoreFailsWhenWorkspaceIsUnreachable` now got as far as `Restore`
  actually attempting to spawn virtiofsd (`fork/exec /usr/libexec/virtiofsd:
operation not permitted` — an unrelated, expected failure on this machine),
  never reporting the blocked ancestor at all — exactly the regression this
  test exists to catch. Every other test, including the two Item 1 tests and
  the three standalone `traversalcheck_test.go` unit tests, stayed green.
  Reverted from a diff-checked copy; suite green again.

**Verification after fix round 3:** all six `go build`/`go vet` combinations
(`linux`/`darwin`/`windows` × `build`/`vet`) exit 0; `go test ./...` for the
whole `remote-worker` module exits 0; `internal/vmpool` alone shows all
pre-existing tests plus the 6 new tests (`TestSameDeviceSiblingDirIsTraversableButNotListable`,
`TestRestoreChecksWorkspaceReachableBeforeVirtiofsd`,
`TestRestoreFailsWhenWorkspaceIsUnreachable`, and the three in
`traversalcheck_test.go`) passing, KVM-gated gates SKIPping as expected on this
machine.

### Final round: both arms run for real, and a decision to stop on Cloud Hypervisor

This section records the actual outcome of running all ten gates against real KVM
and a real golden snapshot, on both arms, to completion. Nothing below was produced
by weakening, skipping, or reinterpreting a gate to get a number — every PASS ran
the real code path to completion, and every FAIL is a real, reproduced failure with
a known signature. That is the reason the rest of this document can be trusted.

**Firecracker: 10/10 PASS, with no environment overrides.** That last part matters
on its own: fix round 2's startup device checks and fix round 3's traversal fix mean
the suite now self-configures correctly rather than needing a hand-tuned rig. Full
per-gate timings from the run:

```
WriteDurability          0.57s
NoCrossRunBleed          1.26s
EmptyKeyIsRefused        0.00s
NoVMReuse                0.75s  (fake_launcher_concurrency AND real_launcher)
SnapshotHoldsNoSecrets   0.41s
LeakFreeTeardown         5.04s
ParkedThenResumed        0.00s
ReclaimThenRedispatch    0.00s
Clock                    0.28s
OutputCapAtSource        0.31s
```

Nine of the ten passed on the first properly-configured run. `TestGateClock` did
not — and it was right not to. It caught a real, shipped defect: the `clockOK`
one-shot latch described above, baked into the golden snapshot's own memory image,
which made every VM restored from that snapshot believe its clock had already been
corrected. Nothing but a correctness gate would ever have found this — it is a
property of the golden snapshot's captured memory, invisible to any launcher-level
or unit-level test, and it would have shipped silently otherwise. **This is the gate
suite's headline result:** a subtle, real defect, caught before it could reach
production, by exactly the class of test spec §8 asked for. After the upstream fix
(`66fdf86`, removing the latch), `TestGateClock` passed in 0.28s, as shown above.

**Cloud Hypervisor: 3/10 PASS, 7 FAIL — a documented stopping point, not a bug still
being chased.** Passing: `TestGateEmptyKeyIsRefused`, `TestGateParkedThenResumed`,
`TestGateReclaimThenRedispatch` — none of these reach a real `Restore()` against a
live guest. Failing: `TestGateWriteDurability`, `TestGateNoCrossRunBleed`,
`TestGateNoVMReuse` (its `real_launcher` subtest; a gate with any failing subtest
counts as failed — see the counting rule at the top of this section),
`TestGateSnapshotHoldsNoSecrets`, `TestGateLeakFreeTeardown`, `TestGateClock`,
`TestGateOutputCapAtSource` — every gate
that actually restores a paused VM and runs a command in it. All seven of these fail
the same way: a 30-second timeout inside `Restore`, during device restoration, right
after cloud-hypervisor's own log shows `Restoring virtio-console __console`.
virtiofsd connects and then immediately disconnects; no error is propagated through
cloud-hypervisor's API for this, which is exactly why it presents as a hang rather
than a diagnosable failure — there is nothing to catch and re-report.

**The project owner has decided to stop pursuing a full Cloud Hypervisor gate pass
and to keep the arm's code as it stands.** This is a decision, not an omission, and
the reasoning is recorded here in full:

- Thirteen fix rounds and roughly eleven rig cycles on this arm reached 3/10, with
  at least one further layer of the same class of problem confirmed to exist beyond
  the virtio-console/virtiofsd disconnect above. There is no evidence this is the
  last layer.
- The A/B the Cloud Hypervisor arm exists to support is limited by **three forced
  non-equivalences** between the two arms that no amount of further fixing removes,
  because they are not bugs — they are how the two VMMs are built:
  1. **Different guest kernels.** Firecracker's CI guest kernel has no
     `CONFIG_VIRTIO_FS`; the CH arm requires a kernel that does. The two arms are
     never running the identical guest kernel image.
  2. **No copy-on-write restore mode on CH v53.0.** `memory_restore_mode` offers
     only `copy` or `ondemand` — there is no equivalent of Firecracker's true
     copy-on-write restore path. Restore-time memory handling is not comparable
     between the arms at that level.
  3. **Different guest memory backing.** Cloud Hypervisor is forced to
     `--memory shared=on` because virtio-fs is a vhost-user device requiring a
     host/guest shared mapping; Firecracker's guest memory stays private. This is
     not a cosmetic difference — it lands directly on spec §7.3's memory-budget
     arithmetic, which assumes a specific backing model.
- Given those three non-equivalences, a full 10/10 CH pass would not have proven
  the two arms equivalent even if reached — the comparison it was meant to support
  is already structurally limited. **The CH arm's purpose has been narrowed
  accordingly**: it now exists to test whether virtio-fs removes the per-run
  serialisation constraint — whether `SerializesExecsPerRun()` can be false and
  D>1 standbys sharing one golden rootfs is actually safe. That question survives
  all three non-equivalences above, and there is already hardware evidence in its
  favor, gathered on this same rig: two guests writing to one shared host directory
  through two separate virtiofsd processes, with no corruption observed; and a
  virtio-fs mount opened `readonly=on` takes a shareable `SharedRead` lock, which
  is what would let N standbys share one golden rootfs without serialising.

No gate was weakened, skipped, or reinterpreted to produce either number above.
Every Firecracker PASS and every Cloud Hypervisor PASS ran to completion against
real KVM and a real golden snapshot; every Cloud Hypervisor FAIL is the same
reproduced 30-second `Restore()` timeout, not a flaky or partial result.

## Performance rungs

### E10 — the lifecycle primitive ladder

**RUN ON BARE METAL. These are the first quotable numbers in this task.**

Host: Supermicro SYS-7049GP-TRT, 72 cpus, 754 GiB, Ubuntu 24.04.4, kernel
6.8.0-1061-nvidia. Verified genuinely bare metal three ways before
`SH_SUBSTRATE=metal` was used anywhere — `systemd-detect-virt` reported `none`, the
DMI product is a physical server, and **0 of 72 cpus carried the hypervisor flag**.
Governor `performance`, swap off, load 0.08, no other users. `ITERS=200 WARMUP=20`.
The golden snapshot was built on that box (spec §2.4) and its rootfs digest was
verified identical before and after every run.

Run twice — the first exposed the replenishment-CPU defect below — and the two agree:

| term                            | run 1    | run 2        |
| ------------------------------- | -------- | ------------ |
| warm hot path p50               | 50.06 ms | **52.74 ms** |
| container baseline p50 (rung 1) | 41 ms    | **41 ms**    |
| ratio                           | 1.22x    | **1.29x**    |
| rung 2 acquire mix (warm/cold)  | 143 / 57 | 143 / 57     |
| replenishment CPU, mean/restore | 10.71 ms | **10.98 ms** |

**§7.2 decision rule: STOP.** Warm hot path 52.74 ms ≥ 15 ms on metal — the design
fails the bar it set itself. The replenishment-CPU row is **row 1, PROCEED** at
10.98 ms per restore.

**Sealed prediction 2 is SUPPORTED** (1.29x, inside 2x). Note what that means beside
the STOP: the warm path is within 2x of the container baseline _and_ 3.5x the 15 ms
bar, because **the baseline is itself 41 ms**. "Within 2x of the baseline" and "fast
enough" are not the same claim.

**The structural finding, and it is not what the design's model assumes.** Rung 2
decomposes as:

    acquire 0.00 ms   resume 28.58 ms   run 2.85 ms   destroy 21.31 ms   total 55.32 ms

A warm acquire is **free** — the median is 0.00 ms, a standby pop — while **resume and
destroy are 49.9 of 55.3 ms**. The design already moved machine _building_ off the hot
path; what remains on it is resume and destroy, and they are the entire cost. Rung 1
having its own 41 ms floor is why the ratio row passes while the absolute row does not.

Driver: `deploy/microvm/e10-lifecycle.sh`; cluster-free proof of its structure:
`deploy/microvm/tests/e10-lifecycle.test.sh`.

### E11 — density, the replenishment ceiling, and the write-up

**RUN ON BARE METAL, 14 rungs, exit 0.** `SH_E11_ACTIVE_RUNS="1 2 4 8 16 32 64"`,
`ITERS_PER_SLOT=20`, `SH_E11_COLD_LATENCY_MS=145`, same host and snapshot as E10.

| c   | microVM tput | p95     | cold | container tput | p95     | cold |
| --- | ------------ | ------- | ---- | -------------- | ------- | ---- |
| 1   | 6.73         | 124 ms  | 0.00 | 9.68           | 78 ms   | 0.00 |
| 2   | 13.01        | 121 ms  | 0.00 | 20.96          | 73 ms   | 0.00 |
| 4   | 23.37        | 142 ms  | 0.03 | 38.15          | 83 ms   | 0.00 |
| 8   | 39.04        | 175 ms  | 0.22 | 55.32          | 124 ms  | 0.00 |
| 16  | 43.31        | 353 ms  | 0.84 | 57.03          | 333 ms  | 0.65 |
| 32  | 35.00        | 788 ms  | 1.00 | 49.15          | 840 ms  | 0.97 |
| 64  | 32.84        | 1686 ms | 1.00 | 41.30          | 2138 ms | 0.99 |

**knee = 8 on both arms, and it is a real knee** — the last _healthy_ rung, not the top
of the sweep: c=16's p95 (353 ms) exceeds twice the c=1 baseline (248 ms). Throughput
peaks at c=16 and then **declines** while p95 grows tenfold to c=64. `bound` is
**replenishment** on both arms.

**Nothing resembling a CPU or memory ceiling was reached.** `hostCpuFraction` is 0.001
flat across the entire ladder and Σ PSS never exceeds 0.41 GB at 128 microVMs. On a
72-cpu / 754 GiB host, what binds is replenishment.

**Sealed prediction 3 is SUPPORTED on both arms**: cold-acquire stays inside the
near-zero band before the knee (0.00, 0.00, 0.03) and rises sharply at and past it
(0.22 → 0.84 → 1.00). It first scored _falsified_ — see the analysis-machinery note
below; the curve was right and the scorer's pre/post split was wrong.

**Sealed prediction 1 is INCONCLUSIVE, stated precisely.** Its scorer needs a threshold
_crossing_ on memory or process count, and this host never produces one. What was
observed is that CPU demonstrably never bound and the knee was replenishment-bound —
consistent with the prediction's direction, but **not a scored result**, and it should
not be reported as one. Confirming prediction 1 on this class of hardware needs a
ladder that reaches an actual memory or process ceiling.

**Prediction 4 is NOT EVALUABLE**: it compares Cloud Hypervisor's virtio-fs against
Firecracker's block, and the CH arm is deliberately off at 3/10 gates — there is no
second arm. **Prediction 5 is INCONCLUSIVE**: `analyzeLadder` cannot score it from a
ladder of `RungSample`; it needs the post-rung convergence series.

#### Three defects in the ANALYSIS machinery, all found only by running at real scale

Each compared the wrong quantity, and two produced a wrong verdict on a sealed
prediction or on the STOP row itself. They are recorded here because the numbers were
never the fragile part — the machinery deciding what they _meant_ was.

1. The §7.2 verdict never asked whether the **warm** rung was warm. At `ITERS=5` the
   standby pool cannot refill between back-to-back Execs, so one acquire in five was
   warm and the rung measured the cold path; the driver printed
   `STOP: warm hot path 69.87ms` from it. Now refused unless warm acquires are a strict
   majority — which is exactly the condition under which a p50 _median_ lands in the
   warm population.
2. The replenishment-CPU row compared `cpu_child_us`, a **run total**, against a
   per-restore threshold, so it scaled with `ITERS`: 1927 ms and `MANDATORY` where the
   real figure is 10.71 ms and row 1. The nested rig had passed that row only because
   `ITERS=5` made the sum small — the same artefact wearing the opposite sign.
3. Prediction 3's scorer split pre/post as "everything except the final rung", which
   only holds if the ladder _stops_ at the knee — and locating a knee requires sweeping
   past it. It now splits on the detected knee.

Driver: `deploy/microvm/e11-density.sh`. Cluster-free proof of its structure:
`deploy/microvm/tests/e11-density.test.sh`. Analysis: `analyzeLadder` in
`experiments/src/microvm-density.ts`, which reuses `detectKnee` (spec §7.3) and scores
predictions pinned in `deploy/microvm/predictions.json`.

#### The original pre-run status, kept for the record

Per the
project owner's resequencing of this endgame — build everything, then
validate hypotheses on a virtualized box, then a reviewed PR, then the metal
run last (pre-run hardware correction F1; a build-time note, not committed) — this task built the sweep
driver and its cluster-free test but did **not** invoke the driver against
any hardware, nested or metal. Every number and verdict below is a **named
blank**, not a placeholder value. No `ssh`, no density sweep, and no
`SH_SUBSTRATE=metal` invocation happened in producing this section.

Driver: `deploy/microvm/e11-density.sh` (requires `SH_SUBSTRATE`,
`SH_SNAPSHOT_DIR`, `SH_WORKSPACE_ROOT`, `SH_MAX_COMMITTED_MB` — no defaults,
so a misconfigured invocation refuses rather than mislabels its own
substrate). Cluster-free proof of its structure:
`deploy/microvm/tests/e11-density.test.sh`. Analysis: `analyzeLadder` in
`experiments/src/microvm-density.ts`, which reuses `detectKnee` (spec §7.3)
and scores predictions pinned in `deploy/microvm/predictions.json`.

#### What a validation run on the nested box can and cannot establish

A nested run (this environment's own `nested-m8i` substrate, never
`nested-c8i`) can establish, end to end: that a sweep run completes without
the driver itself faulting; that Σ PSS sampling from `/proc/<pid>/smaps_rollup`
works and never falls back to RSS; that `analyzeLadder`/`detectKnee` refuse
cheaply on a malformed or lease-saturated ladder; and _which resource_ a knee
in that run is bound by.

> **This paragraph was false when written, and the correction is the point.** The
> final whole-branch review's H2 found that `mem_available_bytes`' awk emitted
> **two** lines on any Linux host (`exit` in a main rule runs the `END` block, and
> the `found` flag its guard tested was never assigned), which put a newline inside
> a JSON numeric value, failed all four `json.load` calls in the rung-record writer,
> and — because the driver runs `set -uo pipefail` **without** `set -e` — lost
> **every rung record** while exiting 0. So the first Linux invocation could not have
> established any of the above: it would have completed the whole sweep having
> recorded nothing, and looked like success. Invisible on darwin, which has no
> `/proc/meminfo` and so took the `|| echo 0` fallback. Fixed, with a Linux-shaped
> `/proc` fixture driven through the existing `SH_E11_PROC_ROOT` seam, a
> `require_numeric` guard on every field of the JSON assembly, and an explicit
> per-rung `die` when a rung writes no record. The claim above holds for the fixed
> driver; it did not hold for the one this section originally described. A nested run **cannot** establish the knee's
> location under real concurrency, an absolute p95, or how close that p95 sits
> to the container baseline — nested virtualization taxes exactly the
> VM-exit-heavy work restore consists of (spec §7.2's own per-substrate
> thresholds already assume this). Every number a nested run would produce is
> a validation result, never a measurement, and must not be quoted as one.

#### Per-rung metrics (spec §7.3)

Sweep dimensions: concurrent active runs (`c`) × `D` (standby depth) ×
`GuestRAMBytes`. The ladder for each (D, GuestRAMBytes) slice must include
`c = 1` as the baseline `detectKnee` requires.

| c   | Exec/sec (p50/p95) | cold-acquire rate | replenishment lag/queue depth | Σ PSS (VMM + virtiofsd) | host MemAvailable / Mlocked / page cache / swap | process count + sysctl/rlimit values | host CPU (+ fraction attributable to replenishment) | ExecErrors by cause | idle standby residency + reclaim convergence time | lease saturations |
| --- | ------------------ | ----------------- | ----------------------------- | ----------------------- | ----------------------------------------------- | ------------------------------------ | --------------------------------------------------- | ------------------- | ------------------------------------------------- | ----------------- |
| 1   | «unrun»            | «unrun»           | «unrun»                       | «unrun»                 | «unrun»                                         | «unrun»                              | «unrun»                                             | «unrun»             | «unrun»                                           | must be 0         |
| …   | «unrun»            | «unrun»           | «unrun»                       | «unrun»                 | «unrun»                                         | «unrun»                              | «unrun»                                             | «unrun»             | «unrun»                                           | must be 0         |

`StandbyIdle` (90s), `WorkspaceIdle` (1800s), `ReplenishDelay` (0.2s) and
`ReclaimScanInterval` (22.5s) are held at their spec §4.1 defaults and
recorded in every rung's JSON output (`e11-density.sh`'s
`static_settings_json`) — not swept, per spec §7.3's own reasoning.

#### Falsifiable predictions (spec §7.4, pinned in `predictions.json`)

| #   | Claim                                                                                                                                                                                                                                                                                                                                                                                                                                            | Verdict         |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------- |
| 1   | Replenishment binds on process/memory count before CPU.                                                                                                                                                                                                                                                                                                                                                                                          | pending (metal) |
| 2   | The warm hot path lands within 2x of the container baseline, because both pay the relay hop and it dominates.                                                                                                                                                                                                                                                                                                                                    | pending (metal) |
| 3   | The knee is a replenishment knee, not a latency knee: cold-acquire rate stays approximately 0 until replenishment rate meets Exec rate, then rises sharply.                                                                                                                                                                                                                                                                                      | pending (metal) |
| 4   | Cloud Hypervisor's virtio-fs costs more per metadata op than Firecracker's block, visible in ls/find-heavy commands rather than in cat.                                                                                                                                                                                                                                                                                                          | pending (metal) |
| 5   | Idle standby residency returns to zero within StandbyIdle + ReclaimScanInterval of a rung's last Exec on an otherwise idle host, while workspace count does not change until WorkspaceIdle; and because a run's final Exec pops a standby and mints its replacement, the run's full complement of D stands idle rather than being reclaimed, so idle standby residency tracks (runs finishing per StandbyIdle) x D x GuestRAMBytes and not zero. | pending (metal) |

`analyzeLadder` scores predictions 1 and 3 structurally from a ladder's
signals; predictions 2, 4 and 5 need data shapes this ladder does not carry
(E10's own rungs, a per-command-class breakdown, and a post-rung
convergence time series respectively) and read `inconclusive` from the
analyzer regardless of substrate — "pending (metal)" here is this
document's own accounting of the sweep never having run, not the
analyzer's output.

#### Arms

- **Firecracker**: driven, block device + mount-at-acquire.
- **Cloud Hypervisor: absent as an arm.** Not because it is slower — it does
  not restore. Every CH run in this environment's correctness gates (see
  above) times out during device restoration with the signature
  `Restoring virtio-console __console`, presenting as a 30-second hang. An
  A/B VMM comparison is dropped for E11; see the correctness-gates section
  above for the full record of that boundary.

Both arms (where CH were present) are driven through the identical
`run_density_rung` function and the identical `grpc_exec_record` RPC call —
`e11-density.sh` has no arm-specific Exec-driving code path.

#### The claim (spec §7.7), structure only

> On a single «nested-m8i | bare-metal» host, `microvm-worker` sustained
> **«N» concurrent in-flight `Exec`s** across **«R» active runs**, at p95
> within **«X»** of the container baseline, with every `Exec` executing in a
> microVM created for it and destroyed after it. The bound observed was
> **«replenishment throughput | host memory | process count»**. Standbys
> resident at that point: **«S»** — a memory statement, not a throughput
> claim.

No blank above is filled. Filling it is the metal run's job, not this task's.

#### Open items carried into the metal run

- **Spec §4.5's repo-cache shape remains undecided.** `e11-density.sh`
  records which of the three named shapes (`two-mounts`, `shared-clone`,
  `accept-cold-fetch`) a run used (`repoCacheShape` in each rung's JSON
  record); it does not choose one, and no ADR amendment was written. See
  pre-run hardware correction F7 (a build-time note, not committed).
- **Model-stub dependency gap.** The driver can take an external
  `SH_E11_MODEL_STUB_CMD` to drive the relay's `Exec` mix, but absent one it
  drives the mix itself directly — a disclosed stand-in for P6 §5.4's model
  stub, not the stub itself.
- **`coldAcquireRate` is a latency-classification proxy**
  (`>= SH_E11_COLD_LATENCY_MS`, default 50ms) at the driver level, not a
  signal read off the pool's own replenishment bookkeeping.
- **`standbysResident` is a proxy** (`max(processCount - c, 0)`), not a
  direct pool-internal count.
- **`leaseSaturations` is always recorded as 0.** The driver bypasses the
  harness lease layer entirely, so this field cannot show a real lease
  refusal; `analyzeLadder`'s guard against `leaseSaturations > 0` is
  exercised only by the unit tests, never by this driver's own output.
- **`MV_LIVE=1` was not attempted.** Out of scope for this task
  (pre-run hardware correction F8; a build-time note, not committed); no placeholder resembling a live run
  was added.

### E12 — guest-initiated vsock on a second port survives snapshot restore

**Two distinct findings, not one boolean.** The core mechanism question issue
#271 asked — does a guest-initiated vsock connection on a second port (1025)
survive a Firecracker snapshot restore — has a clear, reliable **yes**: rungs
A, B and D (fresh boot, single restore, and the host-initiated regression
fence) pass unanimously, and C at N=8 concurrent restores holds the same
result at modest concurrency. Separately, at N=128 concurrent restores from
one snapshot, there is a real, non-zero, non-deterministic failure rate on
this 4-vCPU rig — a distinct scale/capacity finding, not evidence against the
restore mechanism itself. `main()` ANDs every rung together, so C@128's
failure alone flips the run's top-level `ok` to `false`
(`e12-answer.json` from the run: `{"substrate":"nested-m8i","rungs_run":"A B
C D","ok":false}`) even though three of the four rungs, and C's own N=8
point, are unanimous passes.

#### What was actually tested, on `nested-m8i`, in two passes

Rungs A, B, C(N=8), C(N=128) and D were first run standalone (Steps 3-7 of
this task), then again together in one script invocation as the
authoritative combined run (Step 8). Every connection required TWO
INDEPENDENT witnesses: the nonce captured host-side on
`<jail>/vsock.sock_1025`, AND the ACK read back in guest stdout via the
existing agent Exec path on vsock:1024. Neither witness alone was treated as
evidence.

| Rung                                                        | Standalone                                                          | Combined (authoritative)                                                                                                                                               |
| ----------------------------------------------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A (fresh boot, control)                                     | ok=true, both witnesses yes                                         | ok=true, both witnesses yes                                                                                                                                            |
| B (single restore — the core question)                      | ok=true, both witnesses yes                                         | ok=true, both witnesses yes                                                                                                                                            |
| C, N=8 concurrent restores                                  | ok=true, 8/8                                                        | ok=true, 8/8                                                                                                                                                           |
| C, N=128 concurrent restores                                | ok=false, 127/128 (1 failure: `guest_client_exit=1`, `"read: EOF"`) | ok=false, 76/128 (52 failures: 45× `"read: EOF"`, 2× `"connection refused"`, 1× `"connection reset by peer"`, all `guest_client_exit=1` relay-level connection errors) |
| D (regression fence: host-initiated 1024 with 1025 present) | ok=true                                                             | ok=true                                                                                                                                                                |

The per-rung and per-VM JSON records and the run log are rig artifacts, not
committed to this repo (`deploy/microvm/e12-results/` is gitignored) — the
numbers above are the complete record of what they showed.

All observed C@128 failures are `guest_client`-relay-level connection errors
(EOF, connection refused, connection reset) — none show the signature of the
bug fixed in `1ac8371` (that bug produced `guest_client_exit=0` with a
correctly-echoed-but-mis-compared ACK; these are `guest_client_exit=1` with
real connection-level errors). The failure rate is markedly worse when C@128
runs immediately after the other rungs in the same invocation (52/128) than
when it runs alone (1/128) — consistent with resource or scheduling
contention under heavy concurrent boot load on this 4-vCPU rig, not with a
fundamental defect in the vsock-across-restore mechanism itself.

Snapshot integrity was verified pristine (matching `manifest.json`'s
`rootfs_sha256`) before and after every run, both passes — the golden
snapshot was never mutated by this probe.

#### The 4-VM bookkeeping gap in the combined run's C@128

The combined run's per-VM records account for only 48 of the 52 counted
failures: `grep -l '"ok":false' rung-C-128-*.json` finds 48 files, but
`rung-C-128.json` reports `fail_count=52`. Four VM indices (112, 113, 120, 123) have neither a log line nor a per-VM JSON record, yet are still counted
in the aggregate.

This is explained precisely by `run_rung_c_n`'s own control flow
(`deploy/microvm/e12-vsock-egress-probe.sh`). Each per-VM subshell runs:

```
restore_vm "$jail" 2>"$jail.boot.log" || {
  write_json_record "$RESULTS/rung-C-${n}-${i}.json" \
    "{\"rung\":\"rung-C-${n}-${i}\",\"ok\":false,\"error\":\"restore_vm failed\"}"
  exit 1
}
```

That `||` fallback only runs if `restore_vm` _returns_ nonzero. But `die()`
(the script's error primitive) is `die() { echo "e12: $*" >&2; exit 1; }` — a
raw `exit`, not a `return`. Called from anywhere inside `restore_vm`'s call
chain (e.g. `wait_for_socket`'s timeout `die`, or `wait_for_agent`'s, or any
`api_put`/curl failure `die`), it terminates the per-VM subshell immediately,
from wherever it is, bypassing the `|| { write_json_record ...; exit 1; }`
fallback entirely — `exit` never returns control for `||` to catch, it just
ends the process. The aggregation loop's `wait "$pid"` still correctly
observes the nonzero exit and counts it in `fail_count` — the aggregate
**count** is correct — but no per-VM diagnostic JSON gets written for a
`die()`-triggered failure path. This is a real, minor visibility gap in the
driver (not a counting bug, and not a defect in the answer itself): the four
missing indices are failures whose specific cause (which `die` fired, and
where) was captured at run time in each VM's own `.boot.log` file (the
redirect target of `restore_vm`'s stderr above), named
`$JAIL_BASE/rung-c-128-<i>.boot.log` for the failing index `<i>` — a rig
artifact this repo does not archive. It is not being fixed as part of this
plan — hardening the per-VM diagnostic path and archiving these logs is
beyond this throwaway probe's scope, and does not cast doubt on the
`ok_count`/`fail_count` numbers themselves, which are correct.

#### What a nested run establishes here, and what it does not

This ran on `nested-m8i`, never `metal`. Per this driver's design, no
substrate name check gates that choice — the snapshot-integrity guard
(`assert_snapshot_pristine`) is unconditional and mechanical rather than a
check on the substrate's name, so it holds identically on whichever run this
probe is next pointed at.

What this DOES establish: the guest-initiated vsock mechanism — a
pre-created host listener on `<uds>_<PORT>`, no handshake, `vsock_override`
rewriting `uds_path` per restore — works as documented, on real KVM hardware
virtualized one level down, across a real snapshot restore, including under
modest concurrency (N=8).

What this does NOT establish on its own: Firecracker's snapshot/restore
contract assumes matching hardware between snapshot and restore. A nested
pass makes the metal case very likely but does not prove it. Per issue #271,
metal confirmation should ride along with whichever later run builds a metal
snapshot anyway — not worth booking metal time for on its own — and because
the driver's snapshot-integrity guard is unconditional rather than a
substrate name check, running it again on that later metal snapshot needs no
code change.

#### Prediction (spec-style, pinned in `predictions.json` id 6)

> Guest-initiated vsock on a second port (1025) works on a fresh boot and
> survives snapshot restore, for all N concurrent restores of one snapshot,
> because the guest-to-host direction needs no handshake and no host-side
> state beyond the socket file - strictly less state to reset than the
> host-initiated direction already known to survive.

Falsifier: "any rung B, C or D reporting ok=false while rung A reported
ok=true."

**By the letter of the falsifier, this technically fires.** Rung C reported
`ok=false` at N=128 while rung A reported `ok=true` — that is exactly the
condition the falsifier names, and it should be said plainly rather than
argued around. But in the same breath: the prediction's own claim is
specifically about the guest-initiated mechanism surviving restore, and
rungs A, B and D — the rungs that test the mechanism directly, without
concurrency-scale load — support it strongly and unanimously across both
runs, as does C at N=8. The falsifier's wording ("any rung ... reporting
ok=false") was sealed before rung A ran and did not anticipate a
concurrency-scale failure mode distinct from a restore-mechanism failure; it
cannot distinguish "the mechanism doesn't survive restore" from "128
simultaneous restores exceed what a 4-vCPU rig can schedule reliably." This
is a genuine tension between a coarse-grained sealed falsifier and a
nuanced real result. It is recorded here as exactly that tension, not
resolved by picking whichever framing is more convenient: the falsifier
fires on its literal text, and the mechanism it was meant to test is
nonetheless well-supported.

#### Effect on PR #268

P4.1's decision T1 (route all sandbox egress over vsock) is supported by the
core finding (rungs A, B, D and C@8) and should stand. The N=128 finding
should be carried into P4.1's implementation as an open scale/capacity
question — how many concurrent egress connections a single host is expected
to serve, and whether restores should be staggered or rate-limited under
heavy concurrent load — not as grounds to revert to the NIC option (spec
§2). Nothing observed here resembles the restore-mechanism failure that
would force that reversion.

### E13 — rung C@128's failures are its own probe's added workload, not memory and not restore count

**Prediction 7 is falsified, both disjuncts of its own falsifier fired, and
the control rules out the other obvious explanation as well.** E12 left an
open scale question with two candidate causes on the table: host memory
exhaustion under 128 concurrent 256 MiB guests against this rig's ~15 GiB
(prediction 7's claim), or a bare concurrent-restore capacity limit on a
4-vCPU rig (PR #272's own framing). Both were tested on `nested-m8i` and
neither survives. A no-second-port control at the same N=128 is a **clean
128/128 pass**, so 128 concurrent restores of the already-shipped mechanism
are not by themselves the problem. A telemetry-wrapped rerun of E12's own
rung C@128 fails **38/128** with **zero OOM events** and `MemAvailable`
never falling below 12.3 GiB, so memory is not the problem either. What
remains — and what the elimination points at — is contention from the
workload rung C@128's own probe apparatus adds on top of the restores, and
the channel it degrades is the pre-existing Exec path on port 1024, not the
1025 path E12 introduced.

#### The two runs, on `nested-m8i`

Both ran back to back on the same host, under the same 1 Hz memory/OOM
sampler (`e13-mem-telemetry.sh`), within the same 40-second window.

| Run                                                                     | What each VM does after restore                                                                                                                                                                                           | Result                                                        | Wall time | `MemAvailable` floor                       | OOM events |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- | --------- | ------------------------------------------ | ---------- |
| Control, N=128 (`e13-restore-capacity-control.sh`)                      | existing host-initiated Exec on vsock:1024 only, `-command true`; no listener on 1025, no guest-side script, no second port at all                                                                                        | `ok=true`, **128/128**, `fail_count=0`                        | 5.442s    | 15,098,597,376 B (14.06 GiB), ~0.26 GB dip | 0          |
| E12 rung C@128, rerun standalone (`e12-vsock-egress-probe.sh -rungs C`) | one host-side `python3` listener process per VM on `<jail>/vsock.sock_1025`, plus an Exec on 1024 that base64-decodes and runs a `python3` script **inside** the guest to do a real AF_VSOCK connect/send/recv round trip | `ok=false`, 90/128, **`fail_count=38`**, `nonce_collisions=0` | 17.204s   | 13,231,726,592 B (12.32 GiB), ~2.13 GB dip | 0          |

Per-VM and per-rung JSON, the telemetry timelines and the correlation output
are rig artifacts, not committed (`deploy/microvm/e13-results/`,
`e13-control-results/` and `e13-telemetry/` are gitignored, per PR #272's own
precedent) — the numbers here are the complete record of what they showed.
`e12-answer.json` from the rerun is `{"substrate":"nested-m8i","rungs_run":"C","ok":false}`.

Every one of the 38 failures carries the identical signature PR #272
reported: `"guest_client_exit":1` with
`"guest_output":"e12-guest-client: read: EOF"`, and `"host_witness":"no"` /
`"guest_witness":"no"`. Unlike E12's combined run, this rerun has **no
bookkeeping gap** — 38 counted failures, 38 per-VM records, all 128 per-VM
records present — so no `die()`-path failures are hiding here (see E12's
4-VM gap above).

#### Memory is ruled out directly, and prediction 7's premise never materialized

`e13-correlate.py` matched all 128 per-VM records against the memory
timeline: `oom_events_total=0`, `failed_near_oom_event=0`,
`failed_below_low_water=0` (of 38), `ok_near_oom_event=0`,
`below_low_water=0`. `oom-events.log` is zero bytes for both runs. The
floor across the failing run was 13,231,726,592 bytes — **12.32 GiB still
available**, i.e. roughly 80% of the rig's memory free at the worst moment of
a run in which 30% of connections failed. There is no exhaustion here to
correlate against.

The control's timeline undercuts prediction 7's arithmetic premise
independently, before the OOM correlation is even consulted: restoring 128
VMs each configured with 256 MiB moved `MemAvailable` by only ~0.26 GB, not
the ~32 GiB that the "128 × 256 MiB against 15 GiB" admission math implies.
Firecracker faults guest RAM in lazily, so a configured guest size is an
upper bound that trivial post-restore work never approaches. The
concurrent-restore admission budget prediction 7 borrowed from issue #266 is
simply not the binding constraint at this N for this workload. (Caveat: the
control's sampler took only 7 samples across its 5.4s run, so its floor is
coarse; the rung C run has 19.)

#### The failures are not positional, and the rate is not reproducible

The 38 failing indices are 8, 12, 24, 31, 32, 37, 40, 41, 43, 45, 49, 52,
53, 65, 67, 69, 71, 73, 81, 82, 87, 88, 89, 92, 94, 95, 97, 99, 100, 101,
102, 105, 110, 114, 122, 124, 125, 128 — spread from index 8 to 128, with
5 / 8 / 13 / 12 falling in successive quarters of launch order. They are not
clustered at the head or the tail. That mild upward tilt is what a
whole-run contention effect looks like as the burst saturates, not a
threshold being crossed at a particular VM count and everything after it
failing.

The rate itself is highly run-to-run variable and should not be quoted as a
property of the system. Three measurements of the same rung at the same N on
the same rig now exist: **1/128** (PR #272 standalone), **52/128** (PR #272
combined with the other rungs), **38/128** (this rerun, standalone with
telemetry). This rerun's standalone number is nowhere near PR #272's own
standalone number, which is the sharpest available evidence that what is
being measured is a scheduling race, not a capacity threshold. Any future
gate on this must be a repeated-trials distribution, not a single run's rate.

Both runs also finished in seconds — 5.4s and 17.2s — not the minutes that
PR #272's "heavy concurrent boot load" phrasing suggests, and not the slow
grinding degradation a genuine resource-exhaustion failure usually produces.
The 3.2× wall-time difference for an identical restore count is itself a
measure of what the probe apparatus costs.

#### What actually explains it, stated at the confidence the evidence supports

Three differences separate the clean control from the 30%-failing rung C at
the same N and the same restore path: rung C starts **128 additional
host-side `python3` processes** (one listener per VM), it asks each guest to
**spawn a `python3` interpreter and perform a real vsock round trip** instead
of `true`, and it therefore holds each VM alive substantially longer. The
restore count, the restore code path, the rig and the host-initiated Exec
call are common to both. By elimination — memory measured and excluded,
restore count excluded by the control — the cause lies in that added
workload, and the plausible mechanism on a 4-vCPU rig is CPU/scheduling
contention: ~256 extra userspace processes competing with 128 Firecracker
VMMs and the guest agents whose Exec responses are precisely what fails to
be read.

Two honesty caveats on that, in the same spirit as E12's:

- **CPU was never measured.** `e13-mem-telemetry.sh` samples `MemAvailable`
  and the OOM killer, nothing else. "CPU/scheduling contention" is therefore
  an inference from elimination plus the ~1.9 GB and 3.2× wall-time deltas,
  not an observation. Confirming it needs host CPU-utilization and
  run-queue-depth sampling across the burst, plus the cheap discriminating
  experiment this run did not do: rerun the control at N=128 with `-command`
  changed from `true` to the same guest-side `python3` payload but **no**
  1025 listener, which separates the guest-side cost from the host-side
  process cost.
- **The 1025 hop was probably never reached in these 38 cases, and cannot be
  cleared or blamed from these artifacts alone.** `read: EOF` is the
  `guest_client`'s own transport error reading the framed response from
  **vsock:1024**; the guest-side script that would connect to 1025 is
  _delivered by_ that same Exec call. `"host_witness":"no"` on all 38 is
  therefore an expected downstream consequence of the 1024 relay dying, not
  independent evidence about 1025. What can be said is that the failure is
  located in the port-1024 Exec relay and that no failure in this run is
  attributable to the 1025 mechanism; what cannot be said from these
  artifacts is that each guest definitively never attempted the 1025 connect.

#### Prediction (spec-style, pinned in `predictions.json` id 7)

> PR #272's rung C@128 connection failures are caused by host memory
> exhaustion under 128x256MiB guest RAM demand against nested-m8i's 15 GiB
> total (per issue #266's own admission-budget finding on this rig class),
> not by a defect in the guest-initiated vsock-across-restore mechanism E12
> added.

Falsifier: "the control script's fail_count at N=128 is close to zero while
PR #272's own rung C@128 fail_count stayed high, OR the telemetry rerun
shows no OOM-killer activity and MemAvailable never drops near the control
script's failures' timestamps."

**Prediction 7 is falsified, and both disjuncts of its falsifier fired
independently.** The first: control `fail_count=0` while rung C@128 stayed
non-trivial at 38/128. The second: `oom_events_total=0` and a memory floor
12.32 GiB clear of exhaustion. There is no tension to record here and no
reading on which the prediction survives — unlike prediction id 6 above,
whose falsifier fired on the letter of its text while the mechanism it
existed to test was well-supported, this falsifier fired on both its letter
and its substance. The claim's causal content was wrong.

Its second clause — "not by a defect in the guest-initiated
vsock-across-restore mechanism E12 added" — is not thereby shown false; it
is simply not what the falsifier tested, and per the caveat above these
artifacts locate the failure in the 1024 relay rather than in the 1025
mechanism. But that clause was carried along by a claim whose stated cause
is refuted, so it earns no credit from this run.

Worth stating plainly, because it is the part neither this prediction nor PR
#272 anticipated: the control result also falsifies PR #272's own
alternative framing. Its write-up read C@128 as evidence that "128
simultaneous restores exceed what a 4-vCPU rig can schedule reliably."
128 simultaneous restores on this rig are fine — 128/128, in 5.4 seconds.
It is 128 simultaneous restores _plus 256 extra userspace processes doing
real work_ that are not.

#### Effect on PR #268 and P4.1

**T1 (route all sandbox egress over vsock) stands, and on firmer ground than
after E12.** E12 established the mechanism across rungs A, B, D and C@8;
E13 adds that the one rung that failed did not fail in the second-port
CONNECT/data path, that its failures were not memory, and that they were not
the restore concurrency the design would actually have to live with. Nothing
in either run resembles the restore-mechanism failure that would force the
NIC option (spec §2).

**P4.1's open scale/capacity question should be re-scoped, not just carried
forward.** E12 framed it as "how many concurrent egress connections a single
host is expected to serve, and whether restores should be staggered or
rate-limited." The restore-count half of that is answered in the negative at
N=128 for a 4-vCPU rig, so staggering restores is not the lever. The
question that survives is: **how much concurrent CPU-bound work the host and
guests do alongside a restore burst, and whether the agent Exec channel on
1024 stays healthy under it.** Concretely, for P4.1:

1. **Do not carry E12's one-host-process-per-connection shape into the
   implementation.** The probe's per-VM `python3` listener was fine for a
   throwaway diagnostic and is the largest single difference between the
   clean control and the failing rung. Production egress wants one
   multiplexed host-side listener, not a process per VM or per connection.
2. **Treat the Exec relay on 1024 as fallible under concurrent load.** The
   observed failure is an unrelated channel's transport dying while the host
   is busy. Whatever P4.1 builds on top of Exec needs a retry with backoff;
   a single `read: EOF` must not be terminal.
3. **Gate on a distribution, not a run.** 1/128, 52/128 and 38/128 for the
   same rung at the same N means any acceptance threshold needs repeated
   trials. A single clean run proves nothing here, and neither does a single
   bad one.
4. **Measure CPU next time.** The one telemetry axis that would have turned
   this run's inference into a measurement was not collected.
