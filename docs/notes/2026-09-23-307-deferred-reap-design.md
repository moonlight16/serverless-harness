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
