# Runbook: does N `microvm-worker` processes give N× throughput? (issue #259)

The question is binary and one experiment answers it: **is the ~62 Exec/s aggregate ceiling a
property of the worker PROCESS or of the HOST?** Everything below exists to make that answer
unambiguous, because the two outcomes point at completely different follow-up work.

Written after the issue #291 re-run, which changed the numbers #259 was drafted against and
found three instrument defects that will abort this experiment if they are not accounted for.

## Why this is the next experiment, and what it decides

At the operating point that matters — many sessions, each issuing Execs — the host is almost
idle while throughput is flat:

| quantity                   | value                              |
| -------------------------- | ---------------------------------- |
| one session (c=1)          | 17.56 Exec/s                       |
| peak, one worker (c=8)     | 80.62 Exec/s ≈ 4.6 sessions' worth |
| plateau, one worker (c≥16) | ~62 Exec/s ≈ 3.5 sessions' worth   |
| host CPU at the plateau    | **4.81 of 72 cores (6.7%)**        |
| Σ PSS at the plateau       | 1.44 GB of 754 GiB                 |
| `coldAcquireRate` at c≥16  | 1.00 (every Exec pays a restore)   |

Sixty-four sessions asking for work receive the throughput of about four, on a box that is 93%
idle. Restores are **not** serialized by the pool mutex — `replenishOne` calls `p.mu.Unlock()`
_before_ `p.warm(...)` — so they already can overlap. Yet 62 Exec/s against E10's 23.06 ms
restore implies only about **1.4-way effective restore concurrency**. Something in the restore
path serializes and it is not `pool.mu`.

- **If two workers give ~161 Exec/s**, that serializer is per-process. N workers is the answer to
  "maximum possible throughput", and the ~15× CPU headroom says there is a long way to go.
- **If two workers give ~62 Exec/s**, it is host-wide (snapshot memfile page cache, KVM ioctl
  paths, the `/srv` device) and worker parallelism is a dead end — the same trap #259 itself
  warns about from P6, where doubling workers moved the ceiling by −6%. The work then becomes
  de-serializing the restore path, and issue #260's diagnostic half earns its keep.

Either way the experiment is decisive, and it is two points.

## A per-session ceiling that is NOT the thing being tested

`runPool.execGate` is a one-slot channel **per run pool**, held from a successful acquire until
that VM is destroyed, whenever the launcher reports `SerializesExecsPerRun()`. For Firecracker
that is `true` — deliberately, because the workspace ext4 image is not a shared-disk filesystem
and two guests mounting it rw would corrupt it (spec §4.3). Cloud Hypervisor returns `false`.

So **one session executes one Exec at a time**, full acquire→resume→run→destroy, which caps a
single session at about 1/47.75 ms ≈ 21 Exec/s (E10 rung 2's warm total). The measured 17.56 at
c=1 is that ceiling, not a mystery.

Two consequences for this experiment:

- It is **not** the multi-user bottleneck. Different users are different `workspace_key`s, hence
  different run pools, hence different gates. Nothing here serializes across users.
- It **is** a hard capacity-planning fact: no single session exceeds ~20 Exec/s on this design,
  whatever #259 concludes. Do not size a per-user SLO above it without moving to a shared-disk
  workspace filesystem.

## Prerequisites, all three load-bearing

1. **PR #299 must be in the tree.** Without it `pss_bytes_for_pids` refuses on a dying VMM — a
   pid `kill -0` reports alive whose address space is already gone — and in
   `host_signals_snapshot`'s idle-standby-residency poll that refusal is fatal. It fires 4–5
   times per microVM rung and killed the first three-arm run at c=4. Two of four short runs died
   on it.
2. **Use the Go Exec client** (`SH_E11_EXEC_CLIENT=go`). On the grpcurl path the driver was up to
   **23.7%** of the microVM arm's p95 at low `c`; at two-worker throughput it would be back in
   contention for the bottleneck being measured. With the Go client it is under 0.4% at every
   rung.
3. **`SH_E11_COLD_LATENCY_MS=94`**, not the shipped 50 and not the published 145. Derived per
   METAL-RUNBOOK.md §5 from the **Go** client's own warm floor: microVM c=1 p95 82.0 ms plus half
   E10 rung 3's pinned restore p50 (23.06/2). The 145 carries ~42 ms of grpcurl cost the Go client
   never pays.

## Corrected baselines

#259 as drafted says "39.04/s → expect ~78/s if it scales cleanly". Those are pre-#291 numbers.
Use these instead, all from the repaired driver with the Go client on `srv-r16b14s16`:

| c   | one worker, Exec/s | two workers, if it scales linearly |
| --- | ------------------ | ---------------------------------- |
| 8   | **80.62**          | ~161                               |
| 16  | 62.99              | ~126                               |
| 64  | 62.28              | ~125                               |

The **c=8** comparison is the headline: it is the single-worker peak. c=16 and above are past the
knee and already degraded, so a second worker there measures recovery from saturation rather than
clean scaling.

> **It is not a "known-healthy" operating point, and the anchor is an open question.** These rungs
> all ran with the worker's slot count at its default of 4 (`session.DefaultConcurrency`, #305), so
> 80.62 Exec/s is **~4.9 effective slots against a 4-slot cap** — 22% more than the cap can
> produce. The merged campaign doc files that exact figure under **Open** ("Unexplained"), and
> `EXPERIMENTS.md`'s corrected §E11 preamble names `c=8` as the one rung the 4-slot model does not
> predict. Anchor the decision rule on it if you like — it is still the peak that was measured —
> but do so knowing the baseline itself is not understood, and do not read "peak" as "healthy".

## Topology: start shared, fall back to isolated

#259's open question 1 asks whether the workers should share one `SnapshotDir`. **Start shared.**
It is the production topology, and the memory objection is now measured away: Σ PSS is 1.44 GB at
439 resident standbys, and two `MAP_SHARED` + `mlock` mappings of one 256 MiB memfile double the
lock accounting, not the physical pages.

Only if the shared run shows **no** scaling, run a second variant with a per-worker copy of the
snapshot. That discriminates snapshot I/O and page-cache contention from every other host-wide
serializer, and it is the difference between "the host cannot go faster" and "the host cannot go
faster _through one snapshot file_".

### Two concurrent workers need eight things separated and one divided, and NO driver change

`e11-density.sh` has never started two microVM stacks concurrently, but it does not need to be
modified to do so: run it **twice**, concurrently, with these separated. The first three rows and
the ports were verified on the rig rather than assumed; the two marked **⚠** were found afterwards,
by the runs described in the results doc and by the campaign that followed.

Both later additions are the silent kind: the run completes and the numbers look plausible.

| separate                     | default                           | why                                                                                                                                                                                                                                                                                          |
| ---------------------------- | --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RESULTS`                    | `deploy/microvm/.results`         | rung filenames do not encode the worker; the two runs would overwrite                                                                                                                                                                                                                        |
| `SH_CHROOT_BASE`             | `/srv/jail`                       | **the `vm-N` collision — see below.** Each worker's base **must already exist**; the worker does not create it                                                                                                                                                                               |
| `SH_WORKSPACE_ROOT`          | —                                 | run keys are per-driver; same root means two workers in one tree                                                                                                                                                                                                                             |
| `SH_PARENT_CGROUP`           | `microvm.slice/microvm-vms.slice` | **⚠ added — silently destructive.** `microvm-worker` sweeps orphan VM cgroups under it at startup; a worker starting while another runs sweeps the **live** worker's VMs. One run logged "swept 692 VM cgroup(s)". Must be **slice-relative** — jailer refuses an absolute `--parent-cgroup` |
| `SH_E11_STATS_ADDR`          | `127.0.0.1:6061`                  | **⚠ added — silently wrong data.** The driver scrapes this address and passes it to its worker as `SH_DIAG_STATS_ADDR`. Left at the default, **both drivers scrape worker 1's counters** and attribute plausible numbers to the wrong process                                                |
| `SH_E11_RELAY_PORT`          | `8444`                            | one relay per worker                                                                                                                                                                                                                                                                         |
| `SH_E11_REDIS_PORT`          | `6381`                            | one Redis per worker                                                                                                                                                                                                                                                                         |
| `SH_E11_NULL_RESPONDER_PORT` | `8445`                            | one responder per worker                                                                                                                                                                                                                                                                     |
| **divide**, do not separate: |                                   |                                                                                                                                                                                                                                                                                              |
| `SH_MAX_COMMITTED_MB`        | —                                 | per **process**, so two workers at the same value commit twice it — see the budget note below                                                                                                                                                                                                |

The merged campaign doc (`docs/notes/2026-09-22-exec-throughput-campaign-results.md`) states this
as **seven**, counting only the worker-facing variables plus the divided budget: it omits `RESULTS`
and `SH_E11_NULL_RESPONDER_PORT`, which are the driver's own. Same list, different boundary — set
all nine variables above when actually setting up a run.

On `SH_PARENT_CGROUP` specifically: the driver starts the worker under `sudo`, not systemd, and
outside systemd a parent cgroup path that does not exist is a **warning** — the sweep no-ops rather
than aborting (`microvm-worker` keys that on `INVOCATION_ID`). So the slices need not be created in
advance for this experiment, and if they are absent the destructive sweep cannot fire at all. The
separation is still required, because the failure it prevents is the sweep firing **correctly**
against a path the live worker is also using.

**The `vm-N` collision is the one that will bite.** `pool.nextIDLocked` mints ids as
`vmIDPrefix + p.seq` where `p.seq` is a **per-process counter starting at zero**, so two worker
processes both mint `vm-1`, `vm-2`, … and collide on the jail directory and the API socket. The
launcher refuses exactly that, by design:

```
firecracker: restore vm-6: a live VMM already holds this VM id's API socket at
/srv/jail/firecracker/vm-6/root/run/firecracker.socket — refusing to load a snapshot
into another microVM
```

Give each worker its own `SH_CHROOT_BASE` (default `/srv/jail`) and the paths are namespaced, so
the ids may repeat harmlessly. **`SH_CHROOT_BASE` is not in the explicit env list
`start_microvm_stack` builds for the worker, but it reaches it anyway by inheritance** — bash's
`VAR=val cmd` prefix adds to the inherited environment rather than replacing it. Verified on this
rig: `sudo SH_CHROOT_BASE=/srv/jail-w1 driver` → the grandchild worker reads `/srv/jail-w1`. No
code change is required for this experiment.

Keep every base on the **same filesystem device** as `SH_SNAPSHOT_DIR` — the snapshot build
hardlinks between them (METAL-RUNBOOK.md §2). On this rig `/srv` is one device, so
`/srv/jail-w1` and `/srv/jail-w2` are both fine.

**`SANDBOX_ID` is derived** (`e11-microvm-d${d}-ram${ram_mb}`) and is **not** overridable, so both
workers register under the same id. Each has its own relay, so this is expected to be harmless —
but confirm it in the smoke pass rather than assuming, because it is the one shared name left and
a worker attaching to the wrong relay is the "silently wrong data" failure METAL-RUNBOOK.md §3a
exists for. If it does matter, that is the one change the driver would need.

## The run

Two arms, in this order, both microVM-only:

1. **Control, one worker**: re-measure c=8 on the day, in the same session, rather than citing the
   80.62 above. Box state drifts and the comparison must be within-run.
2. **Treatment, two workers**: each driven at c=8 simultaneously, combined throughput compared
   against the control's 2×.

```
SH_SUBSTRATE=metal
SH_E11_ARMS=microvm
SH_E11_EXEC_CLIENT=go
SH_E11_COLD_LATENCY_MS=94
SH_E11_ITERS_PER_SLOT=80          # ~5s window at the microVM arm's rate -> ~20 sampler ticks
SH_E11_SAMPLE_INTERVAL_MS=250
SH_E11_SAMPLE_SLICE_MS=100
SH_E11_SAMPLE_MIN_TICK_MS=200
# SH_MAX_COMMITTED_MB: per PROCESS -- divide it, see below
# SH_E11_VMM_PROC_PATTERN: leave UNSET. See the traps.
```

Then, **per worker**, every variable from the separations table. Nothing here may be left at its
default:

```
# worker 1                                   # worker 2
RESULTS=.../.results-w1                      RESULTS=.../.results-w2
SH_CHROOT_BASE=/srv/jail-w1                  SH_CHROOT_BASE=/srv/jail-w2   # must pre-exist
SH_WORKSPACE_ROOT=/srv/ws-w1                 SH_WORKSPACE_ROOT=/srv/ws-w2
SH_PARENT_CGROUP=microvm.slice/vms-w1.slice  SH_PARENT_CGROUP=microvm.slice/vms-w2.slice
SH_E11_STATS_ADDR=127.0.0.1:6061             SH_E11_STATS_ADDR=127.0.0.1:6062
SH_E11_RELAY_PORT=8444                       SH_E11_RELAY_PORT=8454
SH_E11_REDIS_PORT=6381                       SH_E11_REDIS_PORT=6382
SH_E11_NULL_RESPONDER_PORT=8445              SH_E11_NULL_RESPONDER_PORT=8455
SH_MAX_COMMITTED_MB=204800                   SH_MAX_COMMITTED_MB=204800    # 2 x 200 GiB < 754 GiB
```

`SH_MAX_COMMITTED_MB` is **per worker process** — each holds its own `vmpool.Config` and its own
admission budget, so it must be **divided, not copied**: two workers at 409600 can commit 800 GiB
between them against 754 GiB of RAM. A budget above installed memory means the gate cannot refuse
before the OOM killer arrives, and every density number becomes a measurement of the OOM killer.
The per-worker 204800 above leaves headroom; anything up to ~262144 each is defensible if combined
residency is confirmed to stay inside physical memory. At the densities this experiment reaches
(Σ PSS 1.44 GB at 439 standbys) neither figure binds — but the gate must still be able to refuse.

## What to record

Per rung, per worker, and never summarised away:

- `throughput`, `p95Ms`, `coldAcquireRate`
- `hostCpuFraction`, `hostCpuFractionPeak`, `coresBusy`, **`hostCpuSamples`** — a rung with fewer
  than ~10 ticks cannot support a CPU verdict, and `crosses('cpu')` needs `>= 0.9`
- `pssBytes`, `pssSamples`, **`pssRefusedTicks`**
- `standbysResident`, `standbyDepth`
- `execClient`, `samplingMode`, `coldLatencyThresholdMs`, `runId`
- **Host-wide, not per worker**: total `coresBusy` across both workers, since the whole question
  is whether the host or the process is the limit. Per-worker CPU alone cannot answer it.
- Foreign load throughout. The box is shared; `galmasi` has had long-lived sessions on it.

## Decision rule, fixed in advance

Let `T1` be the control's c=8 throughput and `T2` the two-worker combined throughput.

| observation                | reading                                                                                              |
| -------------------------- | ---------------------------------------------------------------------------------------------------- |
| `T2 >= 1.8 × T1`           | per-process ceiling. Scale out; find the practical N by extending this experiment, not by assuming   |
| `1.2 × T1 < T2 < 1.8 × T1` | partial. Some per-process, some shared. Report the fraction; do not round it to either story         |
| `T2 <= 1.2 × T1`           | host-wide ceiling. Stop scaling out; run the isolated-snapshot variant, then attack the restore path |

Write the rule down before running, and report whichever row fires — including the middle one,
which is the easiest to accidentally round away.

## Traps, all of them observed on this rig

1. **Leave `SH_E11_VMM_PROC_PATTERN` unset.** The jailer chroots, so the VMM's argv is
   `/firecracker --id vm-N` and the absolute install path matches **nothing** — which correctly
   refuses every microVM rung. And because METAL-RUNBOOK.md §1 requires every `SH_*` on the `sudo`
   command line while `discover_pids` is a bare `pgrep -f` that excludes its own pid but not its
   ancestors, any value passed is matched inside `sudo`'s own argv and that process's PSS is summed
   into `pssBytes`. The driver's default is correct and, being a default, cannot self-match.
2. **A `pgrep -f` diagnostic lies over ssh** for the same reason: the remote `bash -c` carries the
   pattern in its argv. Count VMMs by `readlink /proc/*/exe` instead.
3. **`SH_E11_ITERS_PER_SLOT` cannot serve two arms at once**, so this experiment stays microVM-only.
   At the microVM arm's rate, 80 gives ~20 ticks; the container arm at the same setting gives ~1.
4. **Arm order is randomized every run** (`shuffle_e11_arms`, spec §7.5), and the startup banner
   still echoes the configured order. Count rungs rather than reading the banner.
5. **The sampler slows as standbys multiply**: `hostCpuSamples` at c=64 fell 272 → 155 as `D` grew
   to 8 and the PSS walk reached ~500 processes. With two workers the walk covers both. Check the
   count per rung rather than assuming the cadence held.
6. **A microVM rung can still record `pssBytes: 0` with `pssRefusedTicks: 0` and exit 0.**
   `require_vmm` — the parameter that makes a zero Σ PSS a refusal — is passed only by the
   post-load snapshot call sites, not by the in-rung sampler. Treat a zero as suspect, not as data.
7. **`cp -a src dest` onto an EXISTING directory nests it** as `dest/src`. Copy `src/.` into a
   freshly created `dest`, or a completed ladder will look like a stale two-rung one.

## What would confound this experiment

- **Running it past the knee only.** At c≥16 `coldAcquireRate` is already 1.00 and throughput is
  degraded; a second worker there measures recovery, not scaling. c=8 is the clean comparison.
- **Unequal load.** Both workers must be driven at the same `c` and start together. A staggered
  start measures one worker warming while the other is in steady state.
- **Issue #295.** The relay yields an in-stream `ExecEvent.error` and then returns gRPC OK, so on
  the grpcurl path a failed Exec counts toward `throughput` and into `p95`. The Go client
  classifies it correctly, which is a third reason to use it here. If `execErrorsByCause` is empty
  while throughput looks implausibly healthy, suspect this.
- **The unexplained `driver-control` discrepancy.** The published grpcurl `driver-control` table
  does not reproduce past c=1 on this host (see EXPERIMENTS.md §"Issue #291"). It is recorded as an
  open discrepancy, not a diagnosis; it does not touch the microVM arm, but it is a reason to
  re-measure the control in-session rather than cite any stored number.
