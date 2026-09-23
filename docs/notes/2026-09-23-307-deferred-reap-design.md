# Deferring the VM reap off the execGate critical path (#307)

**Status: correctness argument settled on paper. Verdict: PROCEED, with one gap to close by
measurement and one premise of the proposal corrected.**

`ExecPhased` holds `runPool.execGate` from a successful acquire until the VM is fully destroyed.
Destroy's `cmd.Wait` is 19.28 ms at c=1 and 52.48 ms at c=64 (#307, `--keys` driver), and #307
localised it to KVM structure reclamation blocking on RCU/SRCU grace periods under
`kvm_vm_release`. It is latency the kernel absorbs concurrently — Destroy throughput goes 49/s at
c=1 to 1131/s at c=64 — so holding a slot across it converts absorbable latency into occupied
capacity.

The proposal: release the gate after the SIGKILL, and run `cmd.Wait` + jail removal + cgroup
release on a bounded background reaper.

This note settles whether that is safe, because `execGate`'s doc comment says it exists for one
reason and `pool.go`'s defer ordering is deliberate about it.

## What the gate actually protects

The constraint, quoted from `runpool.go`:

> Firecracker's ext4 workspace is not a shared-disk filesystem, so a second guest mounting it rw
> while the first still holds it would corrupt it (spec §4.3).

Three facts from the code fix what that means concretely.

**The mount is guest-side, and it happens inside the gate.** `firecrackerVM.Resume` sends
`mountpoint -q /workspace || mount -o rw,noatime /dev/vdb /workspace` over vsock. The host never
mounts `workspace.img`; it is a virtio-blk backing file. So the invariant is not about host state
at all: **at most one live guest kernel may hold `workspace.img` as a rw-mounted ext4.**

**The image is shared by hardlink, deliberately.** `Restore` does
`os.Link(WorkspaceDir/workspace.img, jailRoot/workspace.img)` for every VM of the run, and says
so: "multiple standbys for one run share the same underlying image, which is safe precisely
BECAUSE only one of them is ever mounted rw at a time". This answers proposal question 2
definitively — **yes, the next Exec of the same run reuses the same `workspace.img` inode.** Not
"probably": the image is created once per run by `ensureWorkspaceImage` under `WorkspaceDir` and
hardlinked into each jail. There is exactly one inode per run.

**Standbys restore UNMOUNTED.** `Resume`'s doc comment: "a standby that stayed mounted across
restores would do exactly that with zero concurrent Execs." So a standby VM has never touched
`/dev/vdb`.

## The decisive evidence is already on the record

#307 measured, and reported as an aside rather than as the answer to this question:

| arm                                                     | `wait4`      |
| ------------------------------------------------------- | ------------ |
| `teardown-standby` — restored, **never resumed or run** | **16.04 ms** |
| `teardown-inflight` — resumed, mounted, ran a command   | 17.48 ms     |

A standby never mounted `workspace.img`. It pays **92% of the reap anyway.**

That is a direct experimental refutation of the idea that `cmd.Wait` is waiting for a mount to be
released. There was no mount. The wait is the same wait. #307 draws the conclusion for the
adjacent question — "which also disposes of the guest-unmount hypothesis" — and it disposes of
this one by the same measurement.

The three-arm probe localises it further: a jailed static binary reaps in 0.41 ms, a live
Firecracker holding an open KVM fd in 0.20 ms, and **98.9% of the floor appears the moment a
snapshot is loaded** — i.e. the moment there is a populated KVM address space to tear down. The
cost is `rcu_barrier` (58%) and `__synchronize_srcu` (28%) under `kvm_vm_release`, 80 of 81
blocking samples.

## Why the task in that window provably cannot write to workspace.img

`/proc/<pid>/stack` during the window, from #307:

```
rcu_barrier <- kvm_mmu_uninit_tdp_mmu <- ... <- kvm_put_kvm <- kvm_vm_release
            <- __fput <- task_work_run <- do_exit
```

`task_work_run` inside `do_exit` places the task **past two earlier stages of `do_exit`**:

- **past `exit_mm()`** — the address space is already gone. `perf` sees `exit_mmap` as a separate
  1.91% of host-wide samples, distinct from this. No guest memory remains mapped.
- **past `exit_files()`** — every file descriptor has already been closed. `exit_files` is what
  dropped the `f_count` that made this `__fput` run at all. `workspace.img`'s descriptor went
  with them.

A task with no address space and no open descriptors cannot issue a write to `workspace.img`. The
19–52 ms is kernel-internal KVM teardown: irq mask notifiers via `kvm_free_pit`, the TDP MMU's
RCU barrier. **The gate's stated purpose is satisfied well before `wait4` returns.**

This is the proposal's hypothesis, and it holds — but not for the reason the proposal gives. See
next section.

## One premise of the proposal is wrong: SIGKILL is not a synchronous barrier

The proposal states the hypothesis as: "the rw mount belongs to the GUEST, which ceases to exist
at SIGKILL (the `kill` sub-phase, 0.55 ms)."

**The guest does not cease to exist when `kill()` returns.** `fcKillProcessGroup` returns once the
signal is queued and the tasks are woken. Each thread dies when it next leaves the kernel; a
thread inside an uninterruptible `pwrite` to the backing file completes it first. `phKill = 0.55 ms`
measures the syscall, not the death.

So gating on "the `kill` sub-phase returned" is **not** by itself sufficient, and this is the one
place the proposal's argument needs repair rather than confirmation. Today the gate is held until
`wait4` returns, which _is_ a hard guarantee that the whole thread group is dead. Deferring the
wait opens a window that is closed today. That is a new race, however small, and it must be named
as one.

Two things bound it, and one closes it.

**Bound 1 — the window is short.** Everything expensive in the exit happens _after_ the threads
are gone. #307's probe arms price the cheap part directly: 0.41 ms to reap a jailed static binary,
0.20 ms to reap a live Firecracker with an open KVM fd. The interval between `kill()` returning
and the last thread leaving userspace is of that order, ≲1 ms, against 19–52 ms of grace period
after it.

**Bound 2 — there is nothing left to write.** `wrapCommand` appends `sync` to every command:

```go
return "cd /workspace\n{ " + cmd + "\n}\n__fc_rc=$?\nsync\n(exit $__fc_rc)\n"
```

`Run` does not return until the guest's `sync` has completed, and `sync` does not complete until
the device has acknowledged every write — which for virtio-blk means the VMM's `pwrite` returned.
**At the instant `Run` returns there are zero unacknowledged writes to `workspace.img`.** So the
window cannot contain any of the command's data. spec §8's write-durability gate is what keeps
that true.

What the window _can_ contain is a spontaneous guest-kernel write: a `jbd2` commit of state
`sync` already committed, or `ext4lazyinit` zeroing inode tables — `mkfsExt4` runs
`mkfs.ext4 -F` with no `-E lazy_itable_init=0`, so background init is on by default. Both write
either already-durable or all-zero content, but neither is a proof.

### Answering question 1: what to gate on

The proposal asks whether there is an observable point where the guest is provably gone but the
reap has not finished, and notes that `proc_gone` tracks `wait4` to within 0.02 ms so `/proc` may
not offer one. Correct — and the reason is now clear: the task is _alive in `do_exit`_ for the
whole window, so `/proc/<pid>` must exist. It is not a zombie. `/proc/<pid>/stat` will not read
`Z` either, because `exit_notify` runs after `exit_task_work`.

`waitForCgroupEmpty` is not the answer either: `cgroup_exit` runs after `exit_task_work`, which is
why the existing call measures 0.04–0.07 ms and "never fires" — it runs after `cmd.Wait` has
already returned.

The candidate that is left is **thread-group emptiness**: `/proc/<pid>/task/` entries, or
`Threads:` in `/proc/<pid>/status`. Non-leader threads are auto-reaped, so each disappears when
its own `do_exit` completes. Whether that happens early (the leader holds the last `kvm` reference
and blocks alone) or late (a vCPU thread blocks in its own `kvm_vcpu_release`) depends on
Firecracker's fd ownership and cannot be settled by reading this repository's Go code.

**That is the one open question, and it is cheap to answer**: extend #334's Destroy decomposition
with a `threads_gone_us` stamp alongside `proc_gone` and `drain_us`, and run it once. If
`threads_gone` lands early relative to `wait4`, it is a real barrier and the gate can be released
on it. If it tracks `wait4`, there is no observable barrier and the change rests on Bounds 1 and 2
alone — at which point the honest thing is to say so in the PR and let the reviewer weigh a ≲1 ms
window against a 1.4x throughput lever, not to quietly ship it as proven.

## Question 3: an exiting process holding an open fd on workspace.img

Safe, and the proposal's own suspicion that "deferral may not change that at all" is correct.

Two host processes holding the same regular file open is not corruption on its own — ext4
corruption comes from two _guest kernels_ caching and writing back the same filesystem's metadata.
The host does not mount the image.

And the current path already SIGKILLs without a clean unmount, so **every** Exec after the first
already mounts an ext4 whose superblock was never marked clean and replays the journal.
`Resume`'s comment treats mounting fresh each time as positively desirable for the adjacent
reason: "it re-reads the device's metadata, retiring the stale-metadata hazard a pre-mounted
standby would carry". Deferring the reap does not introduce dirty-mount recovery; that is the
steady state today.

The fd itself is closed in `exit_files`, _before_ the window we are deferring, as established
above.

## Question 4: what else the "fully destroyed" ordering guarantees

Checked each, and the answer is that the ordering carries less than its comment implies.

**`MaxCommittedBytes` accounting — unchanged.** `pool.destroy` already decrements `rp.inFlight`
and schedules the replenish _before_ calling `vm.Destroy()`:

```go
func (p *pool) destroy(key string, vm VM) {
    p.mu.Lock()
    if rp := p.runs[key]; rp != nil {
        if rp.inFlight > 0 { rp.inFlight-- }
        p.scheduleReplenishLocked(rp)
    }
    p.mu.Unlock()
    if err := vm.Destroy(); err != nil { ... }
}
```

`committedLocked` sums `ready + inFlight + warming`, so **the budget already stops charging a VM
while its VMM is still alive and reaping.** Deferring the tail does not widen that window by one
byte of accounting. It does not widen it physically either: `exit_mm` completes before
`kvm_vm_release`, so the guest RAM is already returned during the expensive part.

**`os.RemoveAll(v.jailRoot)` while the old VMM is alive — keep it in the tail.** It stays after
`cmd.Wait`, exactly where it is now, so nothing changes. (It would in fact be safe earlier —
unlinking an open file or a running binary's text is legal on Linux, and #307 Q4 inventoried what
it frees as 3.5 MiB of jailer exec-file copy, the six hardlinks holding 3.14 GB that this unlink
does not free — but there is no reason to move it and every reason not to.)

**`cgroupPool` reuse — the existing guard is sufficient, and it stays in the tail.**
`release(rel)` reads `cgroup.procs` and refuses to return a cgroup that still lists a pid, counting
a leak instead. Keeping `release` after `cmd.Wait` preserves that exactly. The real cost is
indirect: a cgroup is not returned to the free list until its reap finishes, so under load the pool
mints up to _(in-flight deferred reaps)_ more cgroups than today. Given #255's 5.3x and that dying
cgroups track cumulative VMs since boot, **dying cgroups per rung is a required measurement, not a
nice-to-have.**

**`SweepOrphans` — cannot race.** It is called once, from `microvm-worker/main.go` at startup,
before `pool.Probe` and before the worker serves anything. There is no in-flight deferred reap at
that point in a process's life. The hazard is the mirror image: `pool.Close` must **drain** the
reaper, or a shutdown with reaps outstanding leaks jail directories and cgroups that only the next
startup sweep would collect — which is #255's accumulation by another route. `Close` already has
the pattern and the precedent (`p.inFlightWarms.Wait()`, `p.reclaimDone.Wait()`, and the comment
explaining that a cut-short teardown leaves a live jailer holding an API socket).

## Question 5: bounding the in-flight reaps

Yes, and unbounded is a genuine new failure mode: each exiting VMM holds a pid, a jail directory,
a cgroup not yet returned to the pool, and its fds until `__fput` completes. A cold-acquire storm
would pile them up, and spec §6 requires a storm to stay "counted, never queued unboundedly".

Shape: a fixed-size worker set draining a buffered channel, with the **queue-full path falling
back to reaping inline** — never dropping a reap, never growing without bound. That makes the
degenerate case "exactly today's behaviour", which is the right floor. Counter for the depth and
for how often the inline fallback fires, so a saturated reaper is visible in `Stats()` rather than
inferred from throughput.

## Verdict on correctness

**The argument holds.** The gate exists to keep two live guest kernels from holding one ext4 rw,
and #307 has already measured that 92% of `cmd.Wait` is present for a VM that never mounted the
image at all. The task spends that window past `exit_mm` and past `exit_files`, with no address
space and no descriptors — it cannot write to `workspace.img`. Nothing else the "fully destroyed"
ordering provides is lost: the budget is already released before `vm.Destroy()`, the cgroup guard
and the jail unlink stay in the tail, and `SweepOrphans` is startup-only.

**With one correction and one condition.** The correction: `kill()` returning is not a synchronous
barrier, so the deferral opens a ≲1 ms window that is closed today. The condition: measure
`threads_gone` against `wait4` before shipping, and if there is no early barrier, say plainly in
the PR that the change rests on a ≲1 ms window containing no unacknowledged writes (guaranteed by
`wrapCommand`'s `sync`) rather than on a proof.

## But the value argument is weaker than the proposal states, and the campaign says so

This is the part to settle before spending rig time, and it is not the objection the proposal
anticipates.

The proposal's model is `throughput = slots / per-Exec`, with CPU as the next bound at ~870 Exec/s.
The campaign's own ceiling table contradicts the second half:

| slots  | Exec/s | host CPU | Acquire ms | per-Exec ms | cold rate |
| ------ | ------ | -------- | ---------- | ----------- | --------- |
| **64** | 577.55 | 66.3%    | 4.30       | 104.11      | 0.142     |
| 128    | 524.66 | 70.0%    | 74.44      | 234.20      | 0.553     |
| 256    | 417.24 | 68.3%    | 281.20     | 596.15      | 0.698     |

> **The peak is 64 slots, and CPU is not the bound** — flat at 66-70% across a 4x slot range while
> throughput falls. What binds is the replenishment rate.

Every Exec destroys one VM and needs one restored, so **the restore rate and the Exec rate are the
same quantity.** Throughput peaked at 577/s and _fell_ when pushed. And at 64 slots the pool is
already 14.2% behind — `cold rate 0.142` means one acquire in seven found no standby and paid a
restore inline.

Deferring the reap is a **demand-side** change. It does not restore VMs faster; it asks for them
faster. If ~577 VM/s is the supply ceiling, the win is zero and the cost surfaces in `Acquire` and
the cold rate — the same observable as the rejected cgroup-rmdir deferral, reached by an entirely
different mechanism. Not "work was conserved", but "the consumer was never the constraint".

**Why it is still worth running.** The 64 -> 128 rung is not a clean refutation: adding slots raises
concurrency _and_ turnover together, and the degradation there may be self-inflicted (more
concurrent restores contending in jailer chroot construction, which is 82-85% of sockwait). The
deferral raises turnover at _fixed_ concurrency of 64 — an experiment nobody has run. And there is
25 cores of headroom (47.0 of 72 busy).

So this experiment decides between two ceilings, and both outcomes are worth having:

- **Throughput rises toward 800-900 and cores-busy climbs.** The lever works; CPU is the new bound.
- **Throughput stays near 577 while the cold rate climbs from 0.142 and `Acquire` grows from
  4.30 ms.** Then "the replenish rate binds past 64 slots" sharpens into **"restore supply is
  ~577 VM/s and it is THE ceiling"** — which retires consumer-side optimisation as a family and
  points everything at the restore path. That is a rejection worth recording, not a tuning problem.

### Pre-registered predictions

Written before the run so neither outcome can be rationalised afterwards.

| observable            | "lever works"                                                            | "supply-bound"         |
| --------------------- | ------------------------------------------------------------------------ | ---------------------- |
| Exec/s at 64 slots    | 800-900                                                                  | 560-620 (within noise) |
| cores busy of 72      | rises from 47                                                            | flat near 47           |
| `coldAcquireRateTrue` | stays near 0.142                                                         | climbs past ~0.4       |
| `Acquire` ms          | stays near 4.30                                                          | grows from 4.30        |
| `wait` ms (deferred)  | off the critical path in both cases — a latency win alone is a REJECTION |

A throughput-neutral result is a rejection to record. #332 improved latency by 1.6 ms and lost
9.24% throughput; that is the standard this is held to.

### Also watch

- **Dying cgroups per rung.** #307 held flat at 54-55. Reaps in flight delay `release`, so the pool
  mints more cgroups under load; #255 was 5.3x.
- **The inline-fallback counter.** If the reaper saturates, the arm is silently partly-today.
- **p95.** Per-Exec latency should improve even if throughput does not; that alone is not a win.

## The split, if it goes ahead

`firecrackerVM.Destroy` is already five timed sub-phases. The boundary is after `kill`:

| sub-phase               | cost at c=64  | side of the gate |
| ----------------------- | ------------- | ---------------- |
| `kill`                  | 0.55 ms       | **held**         |
| `wait` (`cmd.Wait`)     | ~52 ms        | deferred         |
| `removeall`             | 5.92-22.72 ms | deferred         |
| `cgroupwait`            | 0.04-0.07 ms  | deferred         |
| `cgrouprmdir` (release) | ~0            | deferred         |

The deferred tail is literally "everything after `kill`", in the order it already runs, so no
internal ordering inside `Destroy` changes.

Shape, keeping the blast radius small:

- **`VM.Destroy()` stays synchronous and idempotent.** Every non-hot-path caller — `Close`, the
  sweep/reclaim goroutine, `replenishOne`'s post-warm branch, `DestroyAllStandbys`, the CHV arm —
  is untouched and keeps today's behaviour. `TestDestroyIsIdempotent` keeps passing unchanged.
- **Add a narrow optional interface** implemented only by `firecrackerVM`, splitting the same body
  at the kill boundary. `pool.destroy` uses it only when `p.serialize` — the one arm with a gate,
  and the only arm where the deferral buys anything.
- **A bounded reaper owned by the pool**: fixed workers, buffered queue, **queue-full reaps
  inline**. The degenerate case is exactly today. Counters for depth and inline fallbacks.
- **`pool.Close` drains it**, next to `p.inFlightWarms.Wait()` and `p.reclaimDone.Wait()`, for the
  reason already documented there: a cut-short teardown leaves state behind that only the next
  startup sweep collects.
- **`Phases.Destroy` must keep meaning what it means.** It currently spans the whole teardown. If it
  silently becomes "kill only" every historical comparison breaks. Report the gate-held part and the
  deferred part as separate terms, and make the sum still reconcile.

Behind an env flag so the arm is an A/B on one binary, not a branch comparison — the campaign's
"vary one thing" lesson.

## Open

- `threads_gone_us` vs `wait4`: is there an early barrier, or only Bounds 1 and 2? (Task for #334's
  instrument, one short run.)
- `mkfs.ext4 -F` leaves `lazy_itable_init` at its default. Worth confirming whether the guest runs
  `ext4lazyinit` at all, since it is the only spontaneous post-`sync` writer identified.

## Addendum: a conservation argument, and a cheaper gate to clear first

Written after the sections above, on reading `replenish.go` and the recorded slot ceiling. It
sharpens the value objection from "weaker than stated" to "there is a second gate, and it is
cheaper to test than to build".

**Exec/s and restores/s are the same number.** Every Exec destroys its VM (`defer destroy()`, no
exceptions) and every VM serves exactly one Exec (standbys restore unmounted, `Resume` mounts,
`Destroy` follows). At steady state the pool cannot consume VMs faster than it produces them, so
**throughput is bounded by the aggregate restore rate, identically.**

The deferred reap does not touch the restore path. And it does not even let replenishment start
sooner, because `pool.destroy` already calls `scheduleReplenishLocked` _before_ `vm.Destroy()` —
the refill is armed while the old VMM is still being reaped, today. **The change is purely
demand-side.**

This also puts the proposal's ~870 Exec/s CPU-headroom estimate on ground the campaign has already
cleared twice. From the recorded ceiling: "CPU is NOT the bound — 66-70% across a 4x slot range
while throughput falls. ~34% of the host is idle and unreachable by more slots. The ~800 Exec/s
extrapolation is dead... The CPU-efficiency arithmetic is fine; the assumption that slots can spend
the headroom is what fails." The deferral is a different mechanism from adding slots, but it spends
the headroom the same way — by asking for VMs faster.

### What the replenish path can actually supply

No global concurrency cap exists: `scheduleReplenishLocked` arms a timer per run and each
`replenishOne` runs on its own goroutine. But it is **sequential per run** — deliberately, "one
timer per slot rather than a burst, so a finished Exec does not create D VMs in the same instant" —
so a single run supplies at most `1 / (restore + ReplenishDelay)`, on the order of 40 VM/s at a
~25 ms restore.

With one key per slot that is ~2560 VM/s of nominal supply at 64 slots against 577/s of demand, and
the low cold rate (0.142) agrees that per-run supply is not the limit. So the ceiling is
**aggregate restore throughput under concurrency** — contention in the shared restore path, which
is 82–85% jailer chroot construction. The 128-slot rung delivering only 524/s while demanding more
is evidence that aggregate ceiling is near 577/s; but that rung also changed concurrency, standby
commitment and queue depth at the same time, so it is confounded and not decisive.

### The cheaper experiment, to run BEFORE implementing

**Measure the aggregate restore ceiling with no Execs at all, at fixed concurrency.** `vmpoolctl
--mode=replenish` cannot answer it: `runReplenishMode` is a serial `for` loop over
`RestoreOne`/`Destroy`, so it measures restore _latency_, not supply _rate_.

A restore-only probe at c=64 across N keys, reporting VM/s, decides the whole question:

- **ceiling ≲650 VM/s** — the deferred reap cannot raise throughput, by conservation. Record it as a
  rejection without writing the reaper, and the 1.4x expectation is retired along with it. This is
  the outcome the campaign data points at.
- **ceiling ≥1200 VM/s** — supply has room, the demand-side lever is live, and the 1.4x is back on
  the table. Then implement.

This is strictly cheaper than building the reaper and discovering the same thing from a null
throughput result, and it cannot be confounded by the change under test because the change is not
in it.

## Measured: the restore+destroy ceiling is ~870/s, and my supply-bound prediction was WRONG

Run 2026-09-23 on `srv-r16b14s16` (72 cpu, 754 GiB, governor `performance`, swap off, host
otherwise idle, `who` empty, load 0.00 before). `--mode=replenish --vmm=firecracker` with the
concurrency fix, `drop_caches` once before each ladder, orphans cleared by cgroup membership
before every rung. `wall_ms/measured` is the rate; the destroy is inside the wall window because a
real host restores and reaps at the same time.

**Ladder 1 — descending 64 to 1, `c=8` repeated last, 400 iterations per slot:**

| c              | restore+destroy /s | p50 restore | p95 restore | failures | dying cgroups |
| -------------- | ------------------ | ----------- | ----------- | -------- | ------------- |
| 64             | 714.61             | 28.18 ms    | 57.84 ms    | 0        | 50 -> 52      |
| 32             | 435.03             | 19.51 ms    | 40.75 ms    | 0        | 52 -> 52      |
| 16             | 264.03             | 15.65 ms    | 27.88 ms    | 0        | 52 -> 52      |
| 8              | 160.56             | 11.71 ms    | 22.89 ms    | 0        | 52 -> 52      |
| 4              | 90.24              | 10.51 ms    | 24.90 ms    | 0        | 52 -> 52      |
| 2              | 51.62              | 11.71 ms    | 24.19 ms    | 0        | 52 -> 53      |
| 1              | 27.78              | 17.28 ms    | 22.95 ms    | 0        | 53 -> 53      |
| **8 (repeat)** | **160.88**         | 11.71 ms    | 23.36 ms    | 0        | 53 -> 53      |

Drift anchor agrees to **0.20%**. Dying cgroups 50 -> 53 across ~53,000 VMs, so #319's pool is
holding and none of this is #255's degradation. Scaling above c=8 is a clean **1.64-1.65x per
doubling** (rate proportional to c^0.72) with **no knee**.

**Ladder 2 — past c=64, `c=128` repeated last, 250 iterations per slot:**

| c                | restore+destroy /s | p50 restore | p95 restore | failures |
| ---------------- | ------------------ | ----------- | ----------- | -------- |
| 256              | 856.28             | 201.32 ms   | 308.61 ms   | 0        |
| **128**          | **872.18**         | 74.57 ms    | 114.66 ms   | 0        |
| 64               | 656.05             | 33.31 ms    | 64.54 ms    | 0        |
| **128 (repeat)** | **875.10**         | 75.53 ms    | 115.31 ms   | 0        |

Drift anchor agrees to **0.33%**. **The pipeline peaks at ~872/s at c=128** and turns over by
c=256, where the rate falls to 856 while restore latency rises 2.7x — capacity spent on queueing.

One honesty note: c=64 reads 714.61 in ladder 1 and 656.05 in ladder 2, an **8.2% spread**. In
ladder 1 it was the first rung after `drop_caches`; in ladder 2 it ran third, after 96,000 VMs.
Dying cgroups moved only 50 -> 54, so that is not the cause. Treat c=64 as ~660-715/s and do not
read a 5% throughput result against it as signal.

### The prediction I pre-registered was falsified

I predicted "restore supply is ~577 VM/s and it is THE ceiling", with the supply-bound outcome as
the likely one. **It is not.** The pipeline delivers 872/s — 1.51x the production 577.55 Exec/s.
The campaign's "past 64 slots demand outruns the replenishment rate" was true of the _slot_ ladder
and I over-read it into a statement about supply. Adding slots raises concurrency, turnover, standby
commitment and queue depth together; this probe raises turnover alone, and supply had room.

### What the numbers now say the deferral is worth

Corroboration first: at c=64 the probe's cycle is 64/714.61 = 89.56 ms, of which restore p50 is
28.18 ms, leaving **61.38 ms** of destroy — against the campaign's **61.51 ms** Destroy at 64 slots.
Two drivers, same quantity, **0.2%** apart. The probe is measuring the right thing.

Every Exec needs exactly one restore and one destroy, and the pipeline that does _only_ those two
peaks at ~872/s. So:

**~870 Exec/s is the hard ceiling on this design at current restore and destroy costs — 1.51x over
577.55.** The proposal's 800-900 estimate is therefore not above what the machine can do; it lands
exactly on the pipeline's saturation point. That is a narrower claim than the CPU-headroom
arithmetic that produced it (which is still retired — the bound is the pipeline, not the idle 34%),
but it arrives at the same number.

Reaching it is not comfortable. Deferring 52.48 ms of a 104.11 ms per-Exec leaves 51.63 ms, i.e.
**demand of 1240 Exec/s at 64 slots against ~870 of supply** — so supply binds, per-Exec settles
near 64/870 = 73.6 ms, and the missing ~22 ms has to surface somewhere. It will surface in
`Acquire`: sustaining 870 restores/s needs ~65 concurrent restores at the 75 ms latency that rate
costs, which 64 sequential-per-run replenish loops can only just cover.

**Revised prediction, replacing the pre-registered pair:** 800-870 Exec/s (1.39-1.51x), with
`Acquire` growing from 4.30 ms toward ~20-25 ms and `coldAcquireRateTrue` rising from 0.142. Under
this model that Acquire growth is **the expected signature of success**, not the cgroup-rmdir
failure mode — the distinction is whether throughput moves with it. Flat throughput plus growing
Acquire is still a rejection.

Records: `srv-r16b14s16:~/i307-ladder1/`, `~/i307-ladder2/`, driver
`~/i307-restore-ceiling.sh`, binary built from this branch at `~/i307-probe/`.

## SETTLED BY MEASUREMENT: `/proc/<pid>/fd` empties at 1.4 ms of a 53 ms reap

The open question above — "is there an observable point where the guest is provably gone but the
reap has not finished?" — is answered. There is, it is not either of the things #307 looked at, and
it is the correctness property itself rather than a proxy.

Measured on `srv-r16b14s16`, `SH_DIAG_PHASES=1`, both barriers timed from the SIGKILL so both are
directly comparable with `wait_us`.

**Serial (`--mode=teardown-inflight`, n=24), zero unobserved:**

| sub-phase     | mean     | median   | min      | max      | share of wait |
| ------------- | -------- | -------- | -------- | -------- | ------------- |
| `kill`        | 6 µs     | 5 µs     | 4 µs     | 22 µs    | —             |
| `threadsgone` | 243 µs   | 238 µs   | 175 µs   | 312 µs   | **1.46%**     |
| `fdgone`      | 1334 µs  | 1294 µs  | 1177 µs  | 2421 µs  | **7.98%**     |
| `wait`        | 17354 µs | 17972 µs | 10271 µs | 22989 µs | 100%          |

**Under load (`--mode=replenish --concurrency=64`, n=1216):**

| sub-phase     | mean     | median   | p95      | max      | unobserved |
| ------------- | -------- | -------- | -------- | -------- | ---------- |
| `kill`        | 115 µs   | 55 µs    | 427 µs   | 1458 µs  | —          |
| `threadsgone` | 1021 µs  | 450 µs   | 2124 µs  | 65271 µs | **12**     |
| `fdgone`      | 1862 µs  | 1408 µs  | 4617 µs  | 8850 µs  | **0**      |
| `wait`        | 53069 µs | 52883 µs | 75728 µs | 88490 µs | —          |

`wait` at c=64 reads 53.07 ms here against #307's 52.48 ms from the `--keys` exec driver — **1.1%
apart**, a third independent corroboration.

### `fdgone` is the barrier; `threadsgone` is not

**`fdgone` is unconditional and always early.** 0 of 1216 unobserved, and **0 of 1216 landed later
than the reap**. Median 1.4 ms, p95 4.6 ms, worst case 8.85 ms — against a 53 ms wait. It is
**3.58% of the reap on the mean and 20.7% at its very worst.**

**`threadsgone` is not usable**, and this is the reason to have measured both rather than picking
the one that sounded sufficient. Under load it has **12 unobserved samples and a 65 ms maximum** —
sometimes the thread group simply does not empty before the leader is reaped. The barrier I
reasoned was "weaker but adequate" is the unreliable one; the one that _is_ the correctness
property is rock solid.

### What this licenses

At 1.4 ms (median) after the SIGKILL the VMM **holds no file descriptor at all**. Not "probably
cannot write to `workspace.img`" — it has no descriptor with which to write to anything, `exit_files`
having dropped every `f_count` before the expensive `__fput` work runs. The remaining **96%** of
`cmd.Wait` is `rcu_barrier` and `__synchronize_srcu` under `kvm_vm_release`.

`os.ReadDir` returning zero entries cannot be a false early positive: before `exit_files` it returns
the descriptors, and a vanished `/proc/<pid>/fd` returns an _error_, which the probe reports as
"cannot tell" rather than as zero — the guard that makes the -1 convention load-bearing. PID reuse
cannot confuse it either, because the child is not reaped until `cmd.Wait`.

**So the design changes, and gets stronger.** The gate no longer needs to rest on quiescence plus a
≲1 ms unmeasured window:

| sub-phase              | c=64 cost                     | side of the gate |
| ---------------------- | ----------------------------- | ---------------- |
| `kill`                 | 0.12 ms                       | **held**         |
| poll to `fdgone`       | **1.4 ms median, 4.6 ms p95** | **held**         |
| `wait` (`cmd.Wait`)    | ~53 ms                        | deferred         |
| `removeall`            | 5.9-22.7 ms                   | deferred         |
| `cgroupwait` + release | ~0                            | deferred         |

Holding the gate to `fdgone` costs ~1.5 ms instead of ~53 ms and is **provable rather than argued**.
The earlier plan to release at `kill` is superseded: it was cheaper by 1.4 ms and very much weaker.

The residual risks named earlier are also retired by this. The `jbd2`/`ext4lazyinit` spontaneous-write
window closes at `fdgone` along with everything else, so `mkfs.ext4 -F` leaving `lazy_itable_init`
at its default no longer matters.

Records: `srv-r16b14s16:/tmp/i307-bar.log` (serial), `/tmp/i307-bar64.log` (c=64).

## Measured: 1.70x on the gate-held path, mechanism confirmed

`--mode=exec --concurrency=64` against **one** `workspace_key`, arms interleaved off/on/off/on,
1200 Execs each, 100 discarded, `drop_caches` once, orphans cleared per rep.

**One key is the point.** The Firecracker launcher `SerializesExecsPerRun`, so all 64 goroutines
queue at that key's single `execGate` and throughput is exactly `1/(gate-held time)`. That makes
this a direct measurement of the critical section the change alters, with nothing else in it.

| arm    | Exec/s    | per-Exec | Acquire | Resume | Run  | **Destroy** | p95     | inline | failures |
| ------ | --------- | -------- | ------- | ------ | ---- | ----------- | ------- | ------ | -------- |
| off    | 21.24     | 47.08 ms | 0.00    | 23.00  | 2.64 | 20.64       | 3297 ms | 0      | 0        |
| **on** | **36.25** | 27.59 ms | 0.00    | 23.24  | 2.65 | **1.49**    | 1785 ms | 0      | 0        |
| off    | 21.34     | 46.85 ms | 0.00    | 22.98  | 2.64 | 20.14       | 3154 ms | 0      | 0        |
| **on** | **36.30** | 27.55 ms | 0.00    | 23.20  | 2.64 | **1.48**    | 1786 ms | 0      | 0        |

**1.704x.** Reproducibility: off 21.24 / 21.34 (**0.5%**), on 36.25 / 36.30 (**0.14%**) — far
inside the 8.2% session spread recorded earlier, so the effect is not drift.

**The mechanism is confirmed term by term, which is what makes this more than a number.**
`Destroy` falls from 20.4 ms to **1.49 ms** — the barrier (measured independently at 1.41 ms
median) replacing the whole reap, exactly as designed. `Resume` (23.00 -> 23.24) and `Run` (2.64 ->
2.64) do not move, so nothing was traded. p95 nearly halves. `Acquire` stays at 0.00 ms, so no cost
reappeared where the cgroup-rmdir deferral's did. `reaps_inline` is 0, so the reaper was never
saturated and the arm was fully applied. Zero failures in 4800 Execs.

Destroy reads 20.4 ms rather than the 53 ms of a 64-slot run because one key serialises the
teardowns too, so each sees c=1 conditions — and 20.4 ms sits right on #307's 19.28 ms `wait` at
c=1. Another corroboration, and a reminder of what this rung is.

### What this does and does not establish

**Established:** the critical section shrinks 1.70x, by removing the reap and nothing else, with
the barrier costing what it was measured to cost. The correctness argument, the barrier, and the
implementation all behave as predicted.

**Not established: end-to-end throughput at 64 slots.** This rung deliberately has one key, so its
absolute Exec/s (21 -> 36) is a critical-section figure, not the 577 Exec/s production number. The
production configuration needs one key per slot (#334's `--keys`), and there the restore+destroy
pipeline ceiling of ~872/s binds instead: the prediction stays **800-870 Exec/s, at most 1.51x**,
with the residue surfacing in `Acquire`. A 1.70x critical-section win against a 1.51x supply
ceiling means **supply, not the gate, is what will bind next** — which is the outcome the ceiling
ladder already pointed at.

That run is the remaining work, and it needs #334 merged; attempting it on this branch alone would
measure c=1 whatever `--concurrency` says, which is the bug #334 exists to fix.

Records: `srv-r16b14s16:~/i307-ab1/`, driver `~/i307-ab.sh`.

## END TO END at 64 slots: 1.12x, and the bound moved to restore supply

`--mode=exec --concurrency=64 --keys=64` (one key per slot, #334), arms interleaved
off/on/off/on, 16,000 Execs per rung, 128 discarded, `drop_caches` once, orphans cleared per
rung, cores-busy differenced from `/proc/stat`.

| arm    | Exec/s     | Acquire   | Resume | Run  | Destroy  | p95       | cores busy    | `coldAcquireRateTrue` | inline | dying |
| ------ | ---------- | --------- | ------ | ---- | -------- | --------- | ------------- | --------------------- | ------ | ----- |
| off    | 576.68     | **0.00**  | 31.86  | 3.86 | 56.41    | 160.77 ms | 28.0/72 (39%) | **0.161**             | 0      | 54→55 |
| **on** | **636.56** | **38.76** | 34.29  | 4.36 | **4.37** | 204.19 ms | 38.1/72 (53%) | **0.731**             | 0      | 55→56 |
| off    | 543.64     | **0.00**  | 32.12  | 3.85 | 59.81    | 185.72 ms | 28.2/72 (39%) | **0.167**             | 0      | 56→55 |
| **on** | **617.01** | **44.86** | 33.45  | 4.21 | **4.46** | 211.30 ms | 37.5/72 (52%) | **0.751**             | 24     | 55→56 |

**off mean 560.16, on mean 626.79 — 1.119x.** Zero failures in 64,000 Execs. Dying cgroups flat
54→56, so this is not #255.

The off arm reproduces the campaign's baseline exactly: **576.68 against 577.55**. Its rep-to-rep
spread is 6.1% (576.68 / 543.64) and the on arm's is 3.2%, so 1.12x clears the noise — but not by
the margin 1.5x would have.

### The mechanism worked and the bound moved, exactly as predicted

`Destroy` falls **56-60 ms to 4.4 ms**: the deferral does what the single-key A/B said it does.
Resume and Run barely move. `reaps_inline` is 0 and then 24 of 16,000 (0.15%), so the reaper was
essentially never saturated and the arm was fully applied.

**And `Acquire` goes 0.00 to ~42 ms while `coldAcquireRateTrue` goes 0.161 to 0.741.** Three of
every four acquires now pay a restore inline. That is the predicted signature, and it is why 1.70x
on the critical section becomes 1.12x end to end: the gate stopped being the constraint and the
**restore supply became it, immediately.**

Cores-busy rose 39% to 52.5% — the right direction, but not saturation, so CPU is still not the
bound. The pre-registered success criterion was "throughput up AND the bound visibly moved to CPU".
Throughput is up and the bound moved, but it moved to **replenishment, not CPU**.

### Why it fell short of the 800-870 prediction

That prediction came from the ~872 VM/s restore+destroy ceiling, and it was the wrong ceiling to
divide by. The probe reached 872/s with its _own_ workers doing the restores. Production restores
through `replenishOne`, which is **sequential per run** — one timer per slot, "so a finished Exec
does not create D VMs in the same instant" — so 64 keys can have at most 64 restores in flight,
each now taking the ~75 ms that rate costs. At a 0.74 cold rate most restores are not even
happening in the background any more: they are inline, inside the Exec, which puts them back on the
very critical path the deferral cleared.

So the achievable ceiling is not 872 but ~630, and the deferral has already reached it.

### Verdict

**Keep it, but as a 1.12x, not a 1.4-1.5x.** It is a real gain above noise, the mechanism is
proven, the correctness rests on a measured barrier, and it costs ~1.5 ms of gate time. But it is
not the lever the issue expected, and the honest headline is that **it converts a gate bound into a
replenishment bound** — p95 gets _worse_ (161 → 204 ms) as a direct result.

The next lever is now sharply identified and it is not this one: **per-run replenishment is
sequential, and with a 1.7x faster consumer that is what binds.** Raising in-flight replenishment
per run (or `StandbyDepth` above its default 2) is the cheap thing to test next, and #274 — a VM
serving several Execs — attacks the same ceiling by needing fewer restores per Exec.

Records: `srv-r16b14s16:~/i307-e2e1/`, driver `~/i307-e2e.sh`. Stacked on #334, whose `--keys`
this rung requires: without it every rung measures c=1 whatever `--concurrency` says.
