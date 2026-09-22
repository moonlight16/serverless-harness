# The restore path does not serialize: seven dead ends, with evidence (issue #303)

This is the durable record of what was **ruled out** while looking for a serializer in the microVM
restore path. It is kept because each row cost real time to eliminate and would otherwise be
re-investigated. Issue #303 is the source; it closes with this preserved.

**There is no restore-path serializer.** What looked like one was a fixed 20 ms retry in
`waitForUnixSocket`, which accounted for ~90% of every restore while the real work took 2.7 ms
(#304, fixed in PR #315). What looked like a knee "downstream of restore" was the worker's 4-slot
concurrency cap (#305) — see the correction in `deploy/microvm/EXPERIMENTS.md` section E11.

## Ruled out

Recorded so nobody re-runs these.

| candidate                                                      | verdict | evidence                                                                                                                                                                                |
| -------------------------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Go `syscall.ForkLock` serializing jailer spawns                | **no**  | Linux builds `forkpipe2.go`, which _refcounts_ concurrent forks rather than serializing them                                                                                            |
| fork page-table copy inflated by the 256 MiB mlocked memfile   | **no**  | microbenchmark: 10,988 spawns/s pinned vs 10,364 unpinned                                                                                                                               |
| jail-directory inode (`i_rwsem`) contention                    | **no**  | 13,961 ops/s for the full 12-op jail lifecycle in one parent dir; 20,770 sharded. ~250x faster than needed                                                                              |
| single-threaded Node relay                                     | **no**  | 0.04-0.09 cores mid-rung (delta-based `/proc/<pid>/stat`)                                                                                                                               |
| one gRPC/HTTP2 connection worker to relay                      | **no**  | the container arm reaches 75-256 Exec/s over the same path                                                                                                                              |
| `cgroup_mutex`, `/dev/kvm`, snapshot page cache, `/srv` device | **no**  | all _shared_ between the two workers in #259's treatment, which still got 2x                                                                                                            |
| a worker-side Go mutex                                         | **no**  | under-load SIGQUIT dump (15 live VMMs): no goroutine in `warm`/`Restore`/`acquire`, no `semacquire` anywhere. Block profile top sites are `selectgo`, `http.roundTrip`, `sync.Pool.pin` |

## What the campaign found instead

The bound was never one serializer. It was four separate things, in order of what they cost:

1. **`session.DefaultConcurrency = 4`** (#305) — a fixed pool of 4 goroutines per worker draining
   the Exec queue, which the driver never overrode. This produced the ~62 Exec/s plateau and the
   apparent `c=8` knee. **2.74x from one environment variable.**
2. **A leaked per-VM cgroup directory** (#255, PR #314) — **5.3x.** Filed as hygiene, with the note
   that it affected no measurement.
3. **Per-VM cgroup create/destroy churn** (#258, PR #319) — **3.25x**, and the rmdir 195.52 to
   0.047 ms.
4. **The 20 ms socket poll** (#304, PR #315) — ~18%, not the 5x first predicted from a
   20 ms-quantized reading.

Two of the four largest wins were defects rather than optimisations, and the two items ranked
highest before the campaign began returned ~18% and nothing.

## Method notes worth keeping

Instrumentation lived on a local `diag/259-serializer-probe` branch (never pushed): per-phase timing
in `Restore`, plus `net/http/pprof` with `SetBlockProfileRate`/`SetMutexProfileFraction` behind
`SH_DIAG_PPROF`. Overhead was negligible — 61.00 Exec/s instrumented vs 58.26 uninstrumented at the
same `coldAcquireRate` ~0.998.

**`microvm-worker` had no pprof endpoint**, and adding one behind an env var would have saved most
of a day. `SH_DIAG_PHASES` phase logging (#317) is what finally made everything after it measurable.

A caution about the SIGQUIT dump, the strongest row in the table above: that same dump showed
exactly **4** goroutines in `session.(*Session).Serve.func5`. That was the answer to the whole
question, visible in the evidence, and it was dismissed as a sampling artifact. The dump correctly
ruled out a mutex. What it was also saying is that nothing was _waiting_ because only four things
were ever running.

Refs: #259, #260, #291, #303, #304, #305
