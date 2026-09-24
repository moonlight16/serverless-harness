# Decomposing the `Resume` phase (#307 follow-up)

**Status: measured. Verdict: `Resume` will NOT yield a multiple, and the leading hypothesis
is refuted. One small structural win is available; the candidate fix the hypothesis implied
is a measured throughput REGRESSION and should not be built.**

`Resume` was the last opaque phase on the `execGate`-held critical path. Every other opaque
phase this campaign decomposed produced a multiple (#258 split restore and destroy, yielding
#304, #307, #315, #317, #319 — the 5.3x, the 3.25x, the 18%, #336's 1.7x). This one does not,
and the reason is worth recording: the dominant term is single-threaded guest-kernel work on
a code path we do not own.

## The instrument

`resume_us` is now decomposed into `vmresume_us` / `vsockdial_us` / `mount_us`, matching the
three steps `firecrackerVM.Resume` performs. `resume_us` is unchanged and still means the
whole phase, which the three sum to — #336 kept `total_us` the same way, because several
campaign tables compare `resume_us` across runs and a silently redefined field reads as a
missing phase rather than as an error.

**Verified before the ladder**, since three probes in this campaign failed only after a long
run had been spent. At c=1 over 24 iterations the three sub-phases sum to 22891 µs against a
`resume_us` of 22916 µs — a **+0.11% residual**, which is `checkNotDestroyed` plus the error
checks. (The p95 residual is −2.2% and is not an error: p95-of-a-sum is not the sum-of-p95s,
because each sub-phase's p95 comes from a different iteration.) **The p50 identity is the check
at c=1 only.** On the concurrent ladder below, p50 is non-additive for the same reason p95 is —
each sub-phase's median comes from a different Exec — and the residual grows with concurrency:
0.53% at 8 slots, 0.78% at 16, 1.76% at 32, 2.68% at 64. That is percentile arithmetic, not
un-instrumented code, and no residual of that size touches the finding that `mount` dominates
at 77.7–80.5%.

## The breakdown

Descending slot ladder, deferred reap ON at every rung (`DeferReapWorkers=64`), 250
iterations per slot, cheapest rung repeated last as an anchor. p50 µs.

| rung | thru/s | total | acquire | resume | `vmresume` | `vsockdial` | `mount` | run  | destroy | coldRate | `reaps_inline` |
| ---- | ------ | ----- | ------- | ------ | ---------- | ----------- | ------- | ---- | ------- | -------- | -------------- |
| 64   | 655.8  | 82180 | 24517   | 35545  | 1192       | 5770        | 27630   | 4542 | 4249    | 0.643    | 377            |
| 32   | 646.6  | 45404 | 1       | 31135  | 563        | 5423        | 24602   | 3811 | 4191    | 0.354    | 0              |
| 16   | 433.0  | 35101 | 1       | 25327  | 412        | 4446        | 20271   | 2927 | 2622    | 0.326    | 0              |
| 8    | 240.6  | 31104 | 1       | 23871  | 361        | 4159        | 19225   | 2762 | 1977    | 0.331    | 0              |
| 8'   | 237.8  | 31596 | 1       | 23896  | 367        | 4172        | 19251   | 2761 | 2027    | 0.343    | 0              |

**Anchor drift, rung 8 vs 8′: +0.10% on `resume`, +0.14% on `mount`, −1.14% on throughput.**
The session held still, so these are readable. (#336 measured 12.4% on one sweep, which
disqualified a whole column.) Every drift figure in this note is labelled with the sweep it
comes from: the arms table below has its own anchor, and quoting one sweep's drift against the
other's table is a mistake an earlier draft of this note made.

The composition is remarkably stable across the whole ladder:

| rung | `vmresume` | `vsockdial` | `mount`   |
| ---- | ---------- | ----------- | --------- |
| 64   | 3.4%       | 16.2%       | **77.7%** |
| 32   | 1.8%       | 17.4%       | **79.0%** |
| 16   | 1.6%       | 17.6%       | **80.0%** |
| 8    | 1.5%       | 17.4%       | **80.5%** |
| 8'   | 1.5%       | 17.5%       | **80.6%** |

Three immediate readings:

- **`vmresume` is not a finding.** `PATCH /vm {state: Resumed}` is 361–563 µs at ≤32 slots
  (361/367 at 8 and 8′, 412 at 16, 563 at 32) and 1.2 ms at 64. Sub-millisecond as predicted;
  the vcpu un-pause is not the cost.
- **`mount` is 78–81% of `Resume` at every rung.** This is the term.
- **`Resume` is BIGGER than the campaign table says.** The task brief put it at ~23 ms of a
  ~102 ms Exec at 64 slots; it is **35.5 ms of 82.2 ms (43.3%)** there. The ~23 ms figure is
  the ≤8-slot value. The on-disk record it was drawn from (`i307-e2e1/s64-rep1-on.json`)
  reads `p50_resume_us=34287` — within 3.7% of this run's 35545, and nowhere near the brief's
  ~23 ms — so the brief's table, not this run, is the thing that was off. The gap between the
  two measurements is an order of magnitude smaller than the error being corrected.

## `run_us` is a free control, and it is what makes `mount_us` interpretable

`Run` dials its own fresh vsock connection and sends one command, exactly as `Resume` does,
and `run_us` covers all of it including a `sync`. So `run_us` prices a complete warm round
trip, against which `mount_us` can be read.

At 8 slots, reading the ladder table above: `run_us` = 2762 µs covers a dial, a round trip, the
command and its `sync`, versus `mount_us` = 19225 µs for a round trip carrying only the mount.
**The mount command's own execution is ~16.5 ms** (19225 − 2762 = 16463 µs), i.e. about 6x a
comparable complete round trip (16463 / 2762 = 5.96). The un-subtracted ratio, 19225 / 2762, is
7.0x; 6x is the one that follows from the subtraction this sentence just did. The arms table's
arm A reads 2756 and 19261 for the same two terms, a 0.2% difference that changes nothing here.

One consequence is worth stating separately: **`vsockdial_us` (4159 µs at 8 slots) is larger
than Run's entire dial + round trip + `sync` (2762 µs).** Both are the ladder's 8-slot row; the
arms sweep reads 4196 and 2756 and the inequality is the same either way. Resume's dial is
therefore not measuring dial mechanics — it is measuring how long the just-unpaused guest takes to become able to answer a
`CONNECT`. `PATCH /vm` returns in 361 µs at that same 8-slot rung; the guest kernel and agent
then have to be scheduled, and that wait lands in `vsockdial_us`.

## The journal hypothesis: present, and refuted as a cost

The hypothesis was that the workspace ext4 is never cleanly unmounted (the previous VM is
`SIGKILL`ed; `wrapCommand`'s `sync` flushes data but does not mark the superblock clean), so
every mount replays the journal.

**The first half is confirmed.** On a `workspace.img` left behind by a real 64-slot run,
`dumpe2fs -h` reports `Filesystem state: clean` — but `needs_recovery` IS set in the feature
flags, and for a journaled ext4 that flag, not `s_state`, is the dirty bit. Loop-mounting it
on the host (with `losetup` outside the timing clock) logs

```
EXT4-fs (loop1): recovery complete
```

so recovery genuinely runs on every mount. Host cost, mount syscall only:

| host loop-mount                                | mean `mount_us`    |
| ---------------------------------------------- | ------------------ |
| dirty, `needs_recovery` (what every Exec sees) | **8584**           |
| clean (2nd / 3rd mount)                        | 4946 / 5167        |
| `data=writeback`                               | 4669               |
| fresh image, with journal                      | 4860 / 5168        |
| fresh image, **`-O ^has_journal`**             | 4625 / 5072 / 4574 |

**The second half is refuted.** Recovery is real but small, and removing it end to end costs
more than it saves. Measured with no code change at all, by passing the unmount as the user
command (`-- 'cd /;' 'umount /workspace'`), which lands it on the same `execGate`-held path a
real fix would occupy. Arms at 8 slots, 2000 iterations each, `A` repeated last as an anchor:

| arm                          | `mount_us` | `run_us` | total | p95 total | thru/s    | fs left          |
| ---------------------------- | ---------- | -------- | ----- | --------- | --------- | ---------------- |
| A `true` (baseline)          | 19261      | 2756     | 31223 | 41986     | 239.2     | `needs_recovery` |
| B `mountpoint -q /workspace` | 19271      | 4066     | 32230 | —         | 233.5     | `needs_recovery` |
| C `cd /; umount /workspace`  | **18710**  | **5052** | 32611 | 44016     | **228.7** | **clean**        |
| A' `true` (anchor)           | 19271      | 2758     | 31322 | —         | 240.0     | `needs_recovery` |

Anchor drift, A vs A′ on this arms rung: +0.07% `resume`, +0.05% `mount`, +0.35% throughput —
so the arm deltas are real. (Distinct from the ladder's own anchor above; these two sweeps
are separate runs and each is read against its own repeat.)

- Arm C **provably applied**: the `fsstate` probe shows `needs_recovery` gone after C and
  present after A, B and A'. This is the check that keeps a silently-failed `umount` from
  being read as "recovery is free".
- Removing recovery saves **551 µs of a 19.3 ms mount — 2.86%.**
- The `umount` that achieves it costs **+2296 µs (+83%) on `run_us`**, on the same gate.
- Net: **−4.38% throughput**, and p95 up 4.8%.

**So the clean-umount fix is a rejection to record, not a fix to tune.** It joins the jail
pool (#332, −9.24%): a component improvement that reverses under load. `data=writeback` and
`-O ^has_journal` are bounded by the same 2.86% ceiling and are not worth building either.

The 64-slot arms are **not readable** and are excluded: the anchor drifted −5.19% on `mount`
and −4.11% on throughput there, and arm C's apparent −5.15% `mount` improvement is
indistinguishable from that drift. The 8-slot rung, where drift was 0.05%, is the evidence.

## Where the 19.3 ms actually goes

Budget for `mount_us` at 8 slots, each term measured:

| term                                | cost         | how                                                                    |
| ----------------------------------- | ------------ | ---------------------------------------------------------------------- |
| ext4 journal recovery               | 0.55 ms      | arm C − arm A                                                          |
| spawning a real binary in the guest | ~1.3 ms each | arm B − arm A; the command spawns `mountpoint` AND `mount`, so ~2.6 ms |
| vsock round trip (no dial)          | < 2.76 ms    | `run_us` with `true`, which also includes a dial                       |
| **unexplained remainder**           | **~13 ms**   | the ext4 mount code path itself                                        |

That remainder is not metadata volume either. On the host, mount cost is nearly insensitive
to geometry across an 8x size change and a 128x inode-count change:

| host image                          | mean `mount_us` |
| ----------------------------------- | --------------- |
| 2 GiB default (what ships today)    | 5568            |
| 2 GiB, `-N 1024 -O ^resize_inode`   | 5235            |
| 256 MiB default                     | 5039            |
| 256 MiB, `-N 1024 -O ^resize_inode` | 5006            |

So there is a geometry-insensitive ~5 ms floor for an ext4 mount on a fast host core. The
guest is **1 vcpu** (`build-snapshot.sh` sets `vcpu_count: 1`) with 256 MiB, and 19.3/5.0 ≈
3.8x is exactly the ratio expected for single-threaded work on one throttled vcpu.

**Conclusion: the mount is CPU-bound in the guest on a fixed ext4 mount path.** Not journal
recovery, not process spawn, not transport, not metadata volume. That is why this phase does
not yield a multiple: there is no lever on it short of not doing it, or not doing it with ext4
on virtio-blk.

## Recommendation

**Do not build the journal fix.** Measured above: −4.38% throughput. Record it with #332.

**One cheap structural win is available: collapse the two post-resume round trips into one.**

Every Exec currently performs two host→guest vsock dials and two round trips — `Resume`'s
mount and `Run`'s command — and nothing happens between them (`ExecPhased` calls `Resume` then
`Run` immediately). Folding the mount into `wrapCommand`'s prologue, so one connection carries
`mountpoint -q /workspace || mount …` and then the user's command, removes Run's dial and one
round trip: **~2.5 ms of a 31.2 ms Exec, ~8% at 8 slots.**

This **corrects a standing note of mine** ("every Exec includes two host→guest vsock dials,
unamortisable because Firecracker closes ESTABLISHED vsock on resume"). That constraint is
real but does not apply here: it forbids carrying a connection ACROSS a resume, and **both of
these dials happen after the resume**. No resume intervenes between them, so one is redundant
with the other rather than required by the protocol.

Two costs to weigh before building it, neither of which the measurement settles:

- It changes error attribution. A mount failure is currently a `RefuseSpawn` refusal; folded
  into the user's command it becomes an exit code, and `Resume`'s doc comment plus
  `launcher.go`'s `VM.Resume` deliberately place the mount "at acquire, not inside Run".
  Merging keeps the property that comment is defending (a fresh mount per Exec, re-reading the
  device's metadata) but does move the failure boundary.
- The saving is latency, and this tier has already been shown to convert latency wins into
  throughput losses twice (#332, and the clean-umount arm above). At 64 slots the bound is
  the replenish rate, not the gate (`coldAcquireRateTrue` 0.643 there), so the conversion is
  weakest exactly where throughput matters most. **It must be measured as throughput at 64
  slots before it is believed.**

**Do not pursue** `data=writeback`, `-O ^has_journal`, or workspace-image geometry: all three
are bounded by the 2.86% recovery share or the geometry-insensitive mount floor.

**If a multiple is wanted from this phase, it is a substrate change, not a tweak.** The mount
is ~19 ms of single-threaded guest work because the workspace is ext4 on virtio-blk. The CHV
launcher already shares `cfg.WorkspaceRoot` with the guest over **virtio-fs**
(`launcher_chv.go`), which has no per-VM filesystem mount to pay. That is the only identified
change that could remove the term rather than shave it, and it is a much larger piece of work
than this task.

One further measurement, if the ~13 ms remainder is worth attributing precisely: have the
guest agent report its own timing. The Request frame already carries `HostUnixNanos` for clock
correction (`sendRequest` in `guestconn.go`, coordinator finding #6), so the host/guest
comparison machinery exists. It would split "the wire" from "ext4" directly. The host-side
evidence above already makes the CPU-bound conclusion the likely one, so this is confirmation
rather than discovery, and it touches the guest agent and the snapshot.

## Reproducing

Instrument: `vmresume_us` / `vsockdial_us` / `mount_us` on the exec phase line and in
`vmpoolctl --json` (`p50_*`/`p95_*`). Rig `srv-r16b14s16`, `SH_SUBSTRATE=metal`, 72 cores,
swap off, governor `performance`, 0 orphans, dying cgroups flat at 48→50 across the ladder.

```
BASE=… VMPOOLCTL=… SH_SNAPSHOT_DIR=/srv/snapshots SH_WORKSPACE_ROOT=/srv/workspaces \
  SH_SUBSTRATE=metal SH_PARENT_CGROUP=microvm.slice/microvm-vms.slice \
  SH_MAX_COMMITTED_MB=131072 bash i307-resume-ladder.sh   # the ladder
  …                                                        bash i307-arms.sh  # the A/B/C arms
```

Records: `srv-r16b14s16:~/i307-resume-verify-200052/` (instrument verification),
`~/i307-resume-ladder-20260923-204339/` (ladder), `~/i307-arms-20260923-204824/` (arms, with
the per-arm `fsstate` proof). Drivers `/tmp/i307-resume-{verify,ladder,arms}.sh`.
