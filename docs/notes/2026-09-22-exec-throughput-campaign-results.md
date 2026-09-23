# Exec/s throughput campaign: 62.99 to 580.60 on one host (9.2x)

Measured on `srv-r16b14s16` — bare metal, 72 cpu / 754 GiB, `systemd-detect-virt` = none, governor
`performance`, swap off, cgroup2 — between 2026-09-20 and 2026-09-22. Driver
`deploy/microvm/e11-density.sh`, microVM arm, Go persistent-connection Exec client, 256 MiB guests.

**One worker process now sustains 580.60 Exec/s at 66% host CPU, up from 62.99.** The remaining
bound is the rate at which the pool can restore VMs, and it is **host-wide**: a second worker
process is worth 1.00x.

## Where the 9.2x came from

| #                     | change                                             | gain      | note                                            |
| --------------------- | -------------------------------------------------- | --------- | ----------------------------------------------- |
| #305 / PRs #312, #313 | raise the worker's slot count off its hard-coded 4 | **2.74x** | one environment variable                        |
| #255 / PR #314        | stop leaking a per-VM cgroup directory             | **5.3x**  | filed as hygiene, "affected no measurement"     |
| #258 / PR #319        | reuse per-VM cgroups from a pool                   | **3.25x** | rmdir 195.52 to 0.047 ms                        |
| #304 / PR #315        | replace the fixed 20 ms socket poll with backoff   | ~18%      | 5x was predicted; see below                     |
| #295 / PR #309        | stop counting a failed Exec as a success           | —         | instrument: it was inflating throughput         |
| #258 / PR #317        | decompose `Destroy` into sub-phases                | —         | instrument: made everything after it measurable |

**These gains do not multiply, and the reason is not that they were measured sequentially** — had
each been measured against the tree immediately before it, they _would_ compose, because that is what
a chain means. Composed they give 2.74 x 5.3 x 3.25 x 1.18 = **56x** against an actual 9.2x.

They do not compose because **each was measured at the slot count and configuration current when it
landed**, and those differ between rows. A fix worth 5.3x while the worker ran few slots against a
leaking cleanup is not worth 5.3x at 64 slots with the leak gone, and several of these were partly
relieving the same bottleneck from different sides. This document's own lesson applies to its own
headline table: an interpretation inherits every configuration it ran under. **Only the endpoints
compose, and those are the claim: 62.99 -> 580.60.**

**Two of the largest wins were defects, not optimisations**, and the two items ranked highest when
the campaign was planned returned ~18% and nothing at all.

## Where the ceiling is now

Slots, on one worker, descending sweep with the cheapest rung repeated last:

| slots  | Exec/s     | p95 ms | host CPU | Acquire ms | Destroy ms | per-Exec ms | cold rate |
| ------ | ---------- | ------ | -------- | ---------- | ---------- | ----------- | --------- |
| **64** | **577.55** | 145    | 66.3%    | 4.30       | 61.51      | 104.11      | 0.142     |
| 128    | 524.66     | 457    | 70.0%    | 74.44      | 117.77     | 234.20      | 0.553     |
| 256    | 417.24     | 1244   | 68.3%    | 281.20     | 267.08     | 596.15      | 0.698     |

**Every `cold rate` in this document is `coldAcquireRateTrue`**, diffed from the worker's
`vmpool.Stats` counters across the rung — **not** the driver's `coldAcquireRate` latency proxy that
#306 discredits. The distinction matters and the records show why: across these same rungs the proxy
reads a saturated **1.000 everywhere**, carrying no information at all, while the true metric tracks
the ladder 0.142 -> 0.698. The driver still emits both, and retains the proxy only for that
comparison.

This also reconciles an apparent conflict with #306, which found >99% of acquires warm at `c=16` and
concluded "the restore was never on the hot path." That was measured **under the 4-slot cap**, where
demand was four slots' worth and the pool kept up easily. Past 64 slots demand outruns the
replenishment rate, and the true cold rate rises to 0.698 — so the restore is on the hot path in
_this_ regime and was not in that one. Both readings are right about their own configuration.

Note also that the argument does not depend on the cold column at all: `Acquire` grows **65x**
(4.30 -> 281.20 ms) while per-Exec grows 5.7x, going from 4.1% to 47.2% of per-Exec time. That is
direct evidence that acquisition is the binding term however coldness is counted.

**The peak is 64 slots, and CPU is not the bound** — flat at 66-70% across a 4x slot range while
throughput falls. What binds is the replenishment rate: past 64 slots demand outruns the rate the
pool restores VMs, so `Acquire` goes 4.30 to 281.20 ms and a rising share of acquires find no
standby ready and pay a restore inline — 0.142 of them at 64 slots, 0.698 at 256.

### Two per-Exec totals, and the gap between them

The `per-Exec ms` column above is the **sum of the instrumented sub-phases**. Wall-clock time per
slot per Exec is `slots / throughput`, and the two are not the same:

| slots | summed sub-phases | wall-clock (`slots / tput`) | residual | residual share |
| ----- | ----------------- | --------------------------- | -------- | -------------- |
| 64    | 104.11            | **110.81**                  | 6.70     | 6.0%           |
| 128   | 234.20            | **243.97**                  | 9.77     | 4.0%           |
| 256   | 596.15            | **613.56**                  | 17.41    | 2.8%           |

The residual is time inside an Exec that no instrumented phase covers. It is not explained here, and
by this document's own rule about unexplained zeros, an unexplained 6% deserves the same treatment:
**treat the summed column as a lower bound on per-Exec cost, and quote wall-clock when the total
matters.**

So `throughput = slots / summed sub-phases` **over-predicts by 2.9-6.4%**, worst at the peak:

| slots  | predicted | measured   | error     |
| ------ | --------- | ---------- | --------- |
| **64** | 614.73    | **577.55** | **+6.4%** |
| 128    | 546.54    | 524.66     | +4.2%     |
| 256    | 429.42    | 417.24     | +2.9%     |

The model still captures the shape — the error is one-signed and shrinking, consistent with a
residual that grows more slowly than the phases do — but "within ~4%" was wrong, and wrong at exactly
the rung this document is about.

## What the host actually spends

| arm           | slots | cores busy of 72 | CPU   | memory used of 754.5 GiB |
| ------------- | ----- | ---------------- | ----- | ------------------------ |
| 1 x 64        | 64    | 47.0             | 65.3% | **8.3 GiB**              |
| 2 x 32        | 64    | 49.1 each        | 68.2% | 8.6 GiB                  |
| 2 x 64        | 128   | 52.5 / 52.2      | 73.0% | 8.7 GiB                  |
| 1 x 64 repeat | 64    | 48.3             | 67.2% | 8.4 GiB                  |

**Memory is not a constraint here, by about two orders of magnitude.** `memAvailable` never fell
below 745.7 GiB in any arm.

That is far below the per-VM accounting. `PerVMBytes` is 288 MiB (256 guest + 32 overhead), so 64
concurrent VMs should cost ~18 GiB and the admission budget for these runs was set to 480 GiB. But
the sharing is copy-on-write over one page-cache-resident file: the **worker** maps the snapshot's
memory file `MAP_SHARED` and mlocks it once via `PinMemoryFile`, and **each VMM then maps that same
file `MAP_PRIVATE`**, so 64 VMs read one physical copy and are charged only for the pages they dirty.
(An earlier version of this note said guest memory was itself `MAP_SHARED`, conflating the worker's
pin with the VMMs' mappings. Measured on 2026-09-23, `/proc/<pid>/maps` reads `256MiB rw-p …/memfile`
— private — with `Rss` 31 MiB and `Private_Dirty` 5.7 MiB of the 256 MiB region, and THP `madvise`
with `AnonHugePages: 0`, so these are 4 KiB PTEs. The density conclusion is unchanged; only the
mechanism was described wrongly. See #307.) Sampling 306 per-VM cgroups found `memory.current` at
0.9 MiB mean and 2 MiB max, `memory.events` all zero, and nothing within 8 MiB of the 288 MiB limit.

So `SH_MAX_COMMITTED_MB` is worst-case **commitment** accounting — what it would cost if every VM
dirtied its whole guest RAM — not residency. Read "`c=256` commits 216 GiB" as a budget reservation,
not as memory consumed.

How conservative, with the division shown rather than asserted:

| comparison                                                              | ratio    |
| ----------------------------------------------------------------------- | -------- |
| per-VM limit against the **worst** VM observed: 288 MiB / 2 MiB         | **144x** |
| per-VM limit against the mean: 288 MiB / 0.9 MiB                        | 320x     |
| this run's admission budget against host memory used: 480 GiB / 8.3 GiB | 58x      |

**144x is the figure to quote**, being the worst case actually measured rather than an average. (An
earlier draft said "roughly 90x", which does not follow from any of these.) The 8.3 GiB host figure
includes an idle baseline of ~7 GiB, so the run's own footprint at 64 concurrent VMs is on the order
of 1-2 GiB.

One caveat on precision: the `pssBytes` field in these records reads 0.026-0.041 GB and should be
treated as a **lower bound only**. It comes from a process walk, and at 580 Exec/s a VM lives ~100 ms,
so the walk samples a moving target; PSS also divides shared pages among their sharers, which is
exactly this case. The `memAvailable`-derived figure is host-level and is the one to quote.

**Consequence for #274:** the workload is CPU- and restore-rate-bound. If per-Exec VM lifetime
reduces restores, memory will not be what stops it.

## A second worker does not help (issue #259 revisited)

Designed as a controlled comparison rather than "add a worker": hold total slots constant and vary
only the process count.

**This is a separate session from the slot ladder above**, which is why its 64-slot anchor reads
580.60 against the ladder's 577.55. The 0.5% spread is well inside the 2.9% within-session drift this
run measured directly by repeating the anchor last, so the two figures corroborate each other rather
than conflict. Nothing downstream turns on which is used: 580.60/62.99 = 9.22 and 577.55/62.99 = 9.17,
both 9.2x. Quoted per session: **the ladder peak is 577.55, the two-worker anchor is 580.60.**

| arm                   | total slots | per-worker Exec/s | aggregate  | vs anchor | p95 ms | host CPU | cold rate |
| --------------------- | ----------- | ----------------- | ---------- | --------- | ------ | -------- | --------- |
| 1 x 64 (anchor)       | 64          | 580.6             | **580.60** | 1.00x     | 144    | 65.3%    | 0.138     |
| **2 x 32**            | **64**      | 289.6, 291.0      | **580.58** | **1.00x** | 146    | 68.2%    | 0.147     |
| 2 x 64                | 128         | 281.3, 280.3      | **561.60** | 0.97x     | 426    | 72.7%    | 0.538     |
| 1 x 64 (drift repeat) | 64          | 563.7             | **563.66** | 0.97x     | 153    | 67.2%    | 0.155     |

**2 x 32 differs from the anchor by 0.02 Exec/s** while the session's own drift, measured by
repeating the anchor last, was 2.9%. The second process cost +2.9 points of host CPU and returned
nothing.

The 2 x 32 arm is the one that answers the question, because it is the only one that holds total
slots fixed. "Just add a worker" (2 x 64) returns 0.97x, which would read as noise or as
over-subscription and settle nothing about whether the replenish loop is per-process.

Host CPU never leaves 65-73% across one or two processes and 64/128/256 slots, so **the idle third
of the host is not reachable by adding workers.** Whatever serialises is host-wide.

2 x 64 does beat 1 x 128 (561.60 vs 524.66), so splitting recovers ~7% of the over-subscription
penalty — but it stays below 64 slots with p95 tripled and the cold rate at 0.538. Over-subscription
is the same replenish-rate wall either way.

### Overlap was verified, not assumed

Per-worker `coresBusy` matched inside each two-worker arm: 49.1/49.1 and 52.5/52.2. That counter is
**host-wide**, so matching values across workers are the proof they genuinely ran concurrently.
Summing it — the obvious mistake — would have destroyed exactly that evidence.

### This corrects #259's interpretation

#259 measured 1.82-1.92x from two workers and concluded the restore serializer was per-process. It
ran with the worker's slot count at its default of 4 (`session.DefaultConcurrency`), so each process
held only 4 Execs in flight and the second
process was relieving a **configuration** cap. Raising that one value gave 2.74x on a single process
and made scale-out worth 1.00x. The measurement was right; its mechanism was the config it ran under.

## What this means for capacity planning

- **One worker process per host.** Fewer ports, relays, Redises, admission budgets and supervision
  paths, and none of the seven separations two workers need.
- **The tier ships at 16 slots, not 64.** `microvmDefaultConcurrency = 16`
  (`remote-worker/cmd/microvm-worker/main.go`, #313) is a deliberate 4x below the measured peak, on
  the principle that "the default must not wander past the evidence" — 16 was the value with a
  measured result behind it when #313 landed, and 64 came later. Reaching 64 requires setting
  `WORKER_MAX_CONCURRENT` explicitly. Whether to move the default is a separate decision from this
  measurement, and it should account for p95 (145 ms at 64 slots) and for the memory budget, not
  throughput alone.
- **Do not raise slots past 64 on this host.** Slots are finished as a lever above that.
- **Add hosts to add capacity** — nothing is shared between them, so that scales linearly where
  processes do not.
- **Raising the per-host number requires needing fewer restores per Exec.** `Resume` + `Destroy` sum
  to **93.70 ms** at the peak: **90.0%** of the 104.11 ms of instrumented sub-phases, or **84.6%** of
  the 110.81 ms wall-clock total. Both are per-VM rather than per-command. That is #274.
- Unchanged throughout: the per-session `runPool.execGate` ceiling of ~20 Exec/s per user
  (Firecracker `SerializesExecsPerRun()` = true). Nothing here raises a single user's rate.

## Four things that were built, measured and rejected

Kept because each is a plausible idea that someone will propose again, and each is now answered with
evidence rather than argument.

| proposal                                                              | verdict             | why                                                                                                                             |
| --------------------------------------------------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| defer the cgroup `rmdir` out of the teardown path                     | **rejected**        | time is conserved into `Acquire`; 64 slots gets _worse_                                                                         |
| `memory.reclaim` before `rmdir` to stop dying-cgroup growth           | **rejected**        | it does stop the growth, but costs ~1.2 s of writeback per VM and hangs worker startup                                          |
| the 1 ms socket-poll cap is costing throughput at 64 slots            | **falsified**       | A/B says the cap costs nothing; the drop it was invoked to explain was dying cgroups degrading the host ~24%                    |
| the 16-slot knee, and the ~800 Exec/s extrapolation from CPU headroom | **retracted twice** | once as a cleanup-leak confound, once as measurement: CPU is flat while throughput falls, so headroom is not spendable by slots |

## Measurement lessons this campaign paid for

These are here because each one produced a wrong published conclusion first.

- **Run ladders descending, repeat the cheapest rung last, and record the leak accumulator per
  rung.** The first slot sweep ran ascending with a cleanup that killed processes but never removed
  directories, so 47,940 stale cgroups accumulated in lockstep with the swept variable and produced a
  knee, a mechanism and a refutation that were all artifacts. What exposed it was the one detail that
  did not fit: **throughput collapsing while the host went idle.**
- **Vary one thing, and hold the total constant.** See the 2 x 32 arm above.
- **An interpretation inherits every configuration it ran under.** #259's two-worker result and
  E11's `c=8` knee were both reproducible and correctly reported, and both meant something other than
  what they said, because `MaxConcurrent=4` was not in the frame. Record the configuration next to
  the number.
- **Treat a zero as absent data until proven otherwise.** Three sub-phase columns read `0.00` because
  the branch predated the instrumentation that fills them. They were nearly published as findings.
- **A cached `go test` "ok" is not a run.** `-count=1` exposed a test that inverted the moment its
  environment variable was set.
- **Do not infer a ratio from quantized data.** #304's "5x win" came from a 20 ms-granular reading in
  which "appears at 2 ms" and "appears at 19 ms" are the same sample. The real gain was ~18%.
- **A clean directory count is not a clean box.** Dying cgroups survive `rmdir`, pinned by page-cache
  charges, and cgroup cost tracks cumulative VMs since boot. `sync; echo 3 > /proc/sys/vm/drop_caches`
  clears them in ~3 s (14,024 to 51, measured) — a reboot is not needed and would silently re-enable
  swap from `/etc/fstab` and reset the governor.
- **`pgrep -f` self-matches through its own ssh and sudo argv.** It reported four concurrent sweeps
  when one was running. Count with `ps` filtered against `bash -c`; never clean up with `pkill -f`.

## Reproducing

`deploy/microvm/e11-density.sh` sets `WORKER_MAX_CONCURRENT` to the slot count and records it in each
rung record, so a rung is self-describing as of **PR #312** (which is the one that changed the driver;
#313 set the worker's per-tier default and never touched it). High rungs need sizing: `c=256` commits
216 GiB across 768 VMs, so raise `SH_MAX_COMMITTED_MB` (480 GiB was used) and `nofile` (the sudo
default of 1024 is exhausted by 768 VMs) on **every** rung including the anchor, or the comparison is
not like-for-like.

Two workers need seven separations, not the five in #259's runbook: `SH_WORKSPACE_ROOT`,
`SH_CHROOT_BASE` (which must pre-exist), `SH_PARENT_CGROUP`, `SH_E11_RELAY_PORT`,
`SH_E11_REDIS_PORT`, `SH_E11_STATS_ADDR` and a divided `SH_MAX_COMMITTED_MB`. Without
`SH_E11_STATS_ADDR` both drivers scrape worker 1's counters and produce plausible numbers attributed
to the wrong process. `SH_PARENT_CGROUP` matters because `microvm-worker` sweeps orphans under it at
startup — one run logged "swept 692 VM cgroup(s)" — so a worker starting while another runs would
sweep the live worker's VM cgroups.

## Open

- **`c=8` peaks at 80.62 Exec/s** in the pre-#305 ladder, which is ~4.9 effective slots against a
  4-slot cap. Unexplained.
- **#274 — per-Exec VM lifetime.** The only remaining throughput lever, and the only item in the
  campaign that can break isolation. Design note first.
- **#316** — a Cloud Hypervisor vhost-user probe consumes virtiofsd's single `accept`. Filed, blocked
  on a systemd + KVM host.
- The cgroup pool does not `rmdir` its `pool-N` directories on worker exit. 173 were left after the
  last run; all were empty, so nothing is charged and this is not the #255 class of leak, but the next
  worker's startup sweep pays to clear them.

Refs: #255, #258, #259, #274, #291, #295, #303, #304, #305, #306, #316
