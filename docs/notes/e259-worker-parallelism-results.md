# Results: is the ~62 Exec/s ceiling per-process or host-wide? (issue #259)

> **CORRECTION, 2026-09-22 — read this before acting on the recommendation below.**
>
> The measurements in this document stand and reproduce. **The recommendation does not: do not
> scale out.**
>
> The per-process component was a hard-coded constant, `session.DefaultConcurrency = 4` — a fixed
> pool of 4 goroutines draining the Exec queue in each worker. `e11-density.sh` never set
> `WORKER_MAX_CONCURRENT`, so this experiment's two workers were **8 slots against 4**, not two
> hosts' worth of capacity. Scale-out "worked" by multiplying the constant, and the 1.82x is what
> 8 slots over 4 slots looks like once per-worker throughput drops the measured 8.8%.
>
> Two later measurements on this same host settle it:
>
> | configuration                         | Exec/s     | vs 1 worker at the default |
> | ------------------------------------- | ---------- | -------------------------- |
> | 1 worker, `MaxConcurrent=4` (default) | 62.99      | 1.00x                      |
> | **2 workers, 4 each — this document** | **123.57** | **1.96x**                  |
> | **1 worker, `MaxConcurrent=16`**      | **172.88** | **2.74x**                  |
> | 1 worker, 64 slots                    | 577.55     | 9.2x                       |
>
> Raising one environment variable on a single worker **beat this entire two-worker result by
> 1.40x**, at +3.6% p95 and without any of the separations two workers need.
>
> And once the cap is lifted, scale-out is worth nothing at all. Holding total slots constant and
> varying only the process count (2026-09-22, same host):
>
> | arm                | total slots | aggregate Exec/s | host CPU |
> | ------------------ | ----------- | ---------------- | -------- |
> | 1 x 64             | 64          | **580.60**       | 65.3%    |
> | **2 x 32**         | **64**      | **580.58**       | 68.2%    |
> | 1 x 64 (drift rpt) | 64          | 563.66           | 67.2%    |
>
> A 0.02 Exec/s difference against 2.9% session drift, for +2.9 points of host CPU. Host CPU never
> leaves 65–73% across one or two processes and 64/128/256 slots, so **the idle third of the host
> is not reachable by adding workers** — what serialises is host-wide, in the restore path.
>
> **Revised guidance: one worker process per host, with `WORKER_MAX_CONCURRENT` raised.** Fewer
> ports, relays, Redises, admission budgets and supervision paths, and none of the seven
> separations to get wrong in production. Raise per-host throughput by needing fewer restores per
> Exec (#274), not by adding processes. Add hosts to add capacity.
>
> **What this document establishes and keeps:** that two workers genuinely overlap (and _how_ to
> prove it — the "`coresBusy` must not be summed" corollary below is what later made the two-worker
> comparison auditable at all), the foreign-load sampling discipline, the instrument defects, and
> the per-session `execGate` ceiling. The experiment was sound; only its frame was incomplete.
>
> **The lesson:** an interpretation inherits every configuration it ran under. This result was
> reproducible and correctly reported, and still meant the opposite of what it said, because
> `MaxConcurrent=4` was not in the frame. Record the configuration next to the number.
>
> Refs: #305 (the cap), #306 (`coldAcquireRate`), #274 (the remaining lever).

**Answer as originally written — superseded above:** it is a property of the WORKER PROCESS, not
the host. Two workers delivered 1.82x one worker's throughput, on a host that was still ~90% idle
at the higher figure. The decision rule's first row fires: **scale out.**

Run on `srv-r16b14s16` (bare metal, 72 cpu, 754 GiB, `systemd-detect-virt`=none, governor
performance, swap off, cgroup2), 2026-09-21, `SH_SUBSTRATE=metal`.

## Tree

PR #299 was still open, so the run tree is main `45dbeae` + #299. The merge was a
fast-forward, so the tree is exactly #299's head:

```
MAIN_SHA  = 45dbeaec2aa4d364b7fef945eaa56cef3be9636b
PR299_SHA = 023571b4e24b11a84b9cfcd9b03a6d32dd65e34d
TREE_SHA  = 023571b4e24b11a84b9cfcd9b03a6d32dd65e34d   (fast-forward)
```

## The decisive pair

Both arms structurally identical: microVM only, Go Exec client, `SH_E11_ACTIVE_RUNS="1 8"`,
`ITERS_PER_SLOT=80`, D=2, 256 MiB guests, `SH_MAX_COMMITTED_MB=262144` per worker,
identical light instrumentation, run back to back.

| quantity                    | control3 (1 worker)     | treat3 (2 workers)                 |
| --------------------------- | ----------------------- | ---------------------------------- |
| throughput, c=8             | **67.76**               | **123.57** (61.34+62.23)           |
| p95 (ms)                    | 139.59                  | 154.66 / 154.35                    |
| coldAcquireRate             | 0.7625                  | 0.8047 / 0.8172                    |
| host coresBusy (NOT summed) | 3.996                   | **7.56 / 7.58**                    |
| hostCpuFraction             | 0.0555                  | 0.1050 / 0.1053                    |
| hostCpuSamples              | 39                      | 41 / 40                            |
| processCount (host-wide)    | 12                      | 24 / 24                            |
| pssBytes                    | 33,015,467              | 38,018,048 / 41,168,896            |
| pssRefusedTicks             | 2                       | 2 / 0                              |
| standbysResident            | 4                       | 16 / 16                            |
| execErrorsByCause           | {}                      | {} / {}                            |
| execClient                  | go-persistent-conn      | go-persistent-conn                 |
| samplingMode                | in-rung-1hz-mean        | in-rung-1hz-mean                   |
| coldLatencyThresholdMs      | 94                      | 94                                 |
| runId                       | 20260921T040800-4118324 | 20260921T041807-4129930 / -4129931 |

`T2 / T1 = 123.57 / 67.76 = ` **1.824**. Rule: `T2 >= 1.8 x T1` (121.97) -> per-process ceiling.

### Corroborating pair

An earlier pair, same config but with asymmetric instrumentation (the treatment carried a
heavy auxiliary sampler the control did not, which biases the treatment DOWN):

|                | control | treat (w1+w2)        | ratio     |
| -------------- | ------- | -------------------- | --------- |
| throughput c=8 | 67.03   | 128.99 (64.09+64.90) | **1.924** |

Both pairs fire the same row; the ratio sits in **1.82-1.92**. The control reproduced to
within 1% across the two pairs (67.03, 67.76), so T1 is solid.

## Overlap is proven, not assumed

The ~8-10s c=8 windows had to actually coincide or T2 would be two solo measurements summed.
`hostCpuFraction`, `coresBusy` and `processCount` are **host-wide** (`host_cpu_fraction`
diffs `/proc/stat`'s aggregate `cpu ` line), so they double as an overlap test:

- Both workers independently recorded `processCount` **24**, exactly 2x the control's 12.
- Both recorded `hostCpuFraction` **0.105**, 1.89x the control's 0.0555.
- Independent confirmation from a 3s `/proc/stat` sampler: true host busy peaked at
  **3.261 cores (control3) -> 6.217 cores (treat3), 1.91x**.

Two workers cannot each observe a host carrying two workers' load unless they were running
at the same time.

**Corollary: `coresBusy` must NOT be summed across workers.** Each worker's figure already IS
the whole host. The host total at T2 is ~7.57 cores, not 15.14.

## What the number does and does not say

- ~~**Scale-out works, and is the answer to the throughput goal.**~~ **SUPERSEDED — see the
  correction at the top.** The per-process component was `session.DefaultConcurrency = 4`, so this
  compared 8 slots with 4. Raising that one value on a single worker returns 2.74x and beats this
  result by 1.40x; with it raised, a second worker returns 1.00x. There is no per-process
  serializer once the cap is lifted.
- **It is not perfectly linear, and the ratio is close to the boundary.** 1.824 is only 1.3%
  above the rule's 1.8 line. Per-worker throughput fell from 67.76 solo to ~61.8 paired,
  **-8.8%**, so a small shared component exists. Reported as measured rather than rounded to
  "it scales".
- **Headroom remains large.** At T2 the host used 7.57 of 72 cores (**10.5%**); Sigma PSS was
  ~40 MB per worker against 754 GiB. Nothing physical is near saturation at two workers, so N
  should be found by extending this experiment, not by assuming linearity continues.
  **This instruction was followed, and the answer was N = 1.** The experiment was extended in both
  directions: raising the slot cap on one worker reaches 577.55 Exec/s at 66% CPU, and a second
  worker at the same total slot count adds nothing. The headroom was real; processes are not what
  spends it.
- **Unchanged:** the per-session `runPool.execGate` ceiling of ~20 Exec/s per user
  (Firecracker `SerializesExecsPerRun()`=true). Nothing here raises a single user's rate.
- **The isolated-snapshot variant was not run**, correctly: the plan gates it on the shared
  run showing NO scaling, and the shared run scaled.

## Foreign load, for defensibility

The box is shared; `galmasi` held a login session throughout. Sampled every 3s across both
decisive windows (344 `/proc/stat` samples):

| user      | mean              | max               |
| --------- | ----------------- | ----------------- |
| `galmasi` | 0.30% of ONE core | 0.30% of ONE core |
| `polkitd` | <=0.66%           | 4.0%              |

`galmasi`'s figure is flat (mean == max) across every sample: an idle shell. The only other
non-run activity was `nv_queue` (NVIDIA kernel threads, ~2-3% of one core). The box was
uncontended.

## Instrument defects found or confirmed

1. **#299 is incomplete.** Its `pid_mm_is_gone` test returns "contribute 0" only when
   `/proc/<pid>/cmdline` is readable AND empty; an _unreadable_ cmdline is treated as
   ambiguous and still refuses. A VMM whose `smaps_rollup` read fails transiently during
   teardown **while its cmdline still reads** therefore still trips the refusal. Observed
   **3 times across 2 runs** (control2 x1, control3 x2), with the heavy auxiliary sampler
   absent, so it is inherent and not induced by extra load. In these runs the refusal was
   _swallowed_ (the `die` fired inside a command substitution, which discards its exit
   status - a shape this file's own comments warn about) and was correctly counted as
   `pssRefusedTicks`, so the ladder survived. It should not be relied on to.
2. **Trap 6 reconfirmed**: `pssBytes: 0` with `pssRefusedTicks: 0` and exit 0, on
   `.results-control3-w1` c=1 and `.results-smoke-w2` c=1. Still unfixed; treat as suspect.
3. **A fifth separation the runbook's four omit: `SH_PARENT_CGROUP`.** Both workers share
   `microvm.slice/microvm-vms.slice`, and `microvm-worker` runs a startup orphan sweep over
   it - w2 logged "swept 692 VM cgroup(s) from a previous incarnation". Harmless here only
   because both workers start simultaneously, before either has VMs. **A worker starting
   while another is already running would sweep the live worker's VM cgroups.** This matters
   directly for the scale-out recommendation and should be fixed before N workers are started
   independently.
4. **`standbysResident` and `processCount` are not per-worker** when two workers share a host:
   both are host-wide, so each worker counts the other's VMMs as its own standbys (16 each at
   T2, where the true per-worker figure is ~8). Useful as an overlap probe, misleading as a
   density metric.

## Notes for whoever repeats this

- The four separations hold exactly as the runbook says. Verified, not assumed: both workers
  registered the identical derived `SANDBOX_ID` (`e11-microvm-d2-ram256`) yet attached to
  their own relays (`localhost:8444` / `localhost:8454`), and both jail bases minted the same
  ids (`vm-6`, `vm-9`, `vm-15`) with no collision refusal.
- `SH_E11_COLD_LATENCY_MS=94` is correctly placed: the run's own c=1 p95 was 67.97-78.08 ms,
  so the threshold sits above the warm floor with headroom, and `coldAcquireRate` at c=1 came
  out 0.0-0.0375 rather than pinned at 1.0.
- **Do not drop the c=1 rung to synchronise the workers.** A `ACTIVE_RUNS="8"` run starts with
  a fully cold pool: `coldAcquireRate` 0.9984 and throughput 58.26 vs 67.76 for the same
  worker with a c=1 rung ahead of it. Structure must match between arms.
- **A VMM cannot be attributed to a worker by its chroot.** The jailer chroots, so
  `/proc/<pid>/root` reads `/` and argv is `/firecracker --id vm-N`. Walk ppid up instead:
  the parent is `<RESULTS>/.e11-microvm-worker-bin`, whose path encodes the worker.
- Any `/proc` probe of the VMMs must run as **root**; an unprivileged
  `ls -l /proc/*/exe | grep -c firecracker` silently reports 0.
- `pgrep -f` / `pkill -f` self-match through the ssh `bash -c` argv. This cost a monitor that
  never fired and, separately, killed a live session mid-run. Count by
  `readlink /proc/*/exe`; kill by recorded pid.

## Artifacts

26 rung/ladder JSON records under `~/e259-run/.results-{smoke,control,control2,control3,treat,treat3}-w{1,2}/`
on the rig, archived at `~/e259-results.tgz` (157 MB, includes relay/worker/exec-driver logs).
`deploy/microvm/predictions.json` and `EXPERIMENTS.md` untouched;
`pnpm -C experiments exec vitest run microvm-predictions` passes 3/3, exit 0.
Box left clean: 0 VMMs, all driver ports clear, 0 scratch redis containers.
