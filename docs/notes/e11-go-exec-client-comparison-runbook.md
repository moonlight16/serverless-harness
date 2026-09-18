# Runbook: comparing E11's two Exec clients (issue #294)

The question is narrow: **how much of the `driver-control` arm's cost was `grpcurl`?** One
variable moves — `SH_E11_EXEC_CLIENT` — and everything else is held at the values that
produced the table in `EXPERIMENTS.md` §E11.

## The reference to beat

Bare metal, `srv-r16b14s16`, 72 cpu / 754 GiB, `virt: none`, governor `performance`, gawk.
`SH_E11_ARMS=driver-control`, `ITERS_PER_SLOT=200`, `SAMPLE_INTERVAL_MS=250`.

| c   | tput/s | p95    | hostCpuFraction | hostCpuFractionPeak | coresBusy /72 | hostCpuSamples |
| --- | ------ | ------ | --------------- | ------------------- | ------------- | -------------- |
| 1   | 56.8   | 17 ms  | 0.0204          | 0.0253              | 1.47          | 15             |
| 2   | 101.3  | 19 ms  | 0.0411          | 0.0470              | 2.96          | 17             |
| 4   | 171.6  | 25 ms  | 0.0879          | 0.1050              | 6.33          | 20             |
| 8   | 241.6  | 44 ms  | 0.2017          | 0.2131              | 14.52         | 25             |
| 16  | 219.6  | 137 ms | 0.4163          | 0.4864              | 29.97         | 46             |
| 32  | 204.9  | 340 ms | 0.7564          | 0.8069              | 54.46         | 72             |
| 64  | 231.6  | 753 ms | 0.8907          | 0.9598              | 64.13         | 103            |

## Run both arms

Same host, same session, back to back. `SH_E11_RUN_ID` differs per invocation by default, and
`assemble_ladder` only collects rungs from the run that built the ladder, so the two ladders
cannot contaminate each other — but move the results aside between runs anyway, because the
filenames do not encode the client.

```bash
export SH_SUBSTRATE=metal
export SH_E11_ARMS=driver-control
export SH_E11_ACTIVE_RUNS="1 2 4 8 16 32 64"
export SH_E11_ITERS_PER_SLOT=200
export SH_E11_SAMPLE_INTERVAL_MS=250

SH_E11_EXEC_CLIENT=grpcurl bash deploy/microvm/e11-density.sh
mv deploy/microvm/.results deploy/microvm/.results-grpcurl

SH_E11_EXEC_CLIENT=go bash deploy/microvm/e11-density.sh
mv deploy/microvm/.results deploy/microvm/.results-go
```

## Before quoting any number

- **`hostCpuSamples` per rung.** A mean of one or two ticks cannot score a saturation
  verdict, and the driver warns at run time when a rung produced fewer than five. The
  reference run's 15–103 is healthy at these settings; a faster client produces _shorter_
  windows, so the Go run's counts will be lower and may need `ITERS_PER_SLOT` raised.
- **`execClient` in every record.** If it says `grpcurl-per-exec` in the `.results-go`
  directory, the env var did not take and the comparison is of one client with itself.
- **`SH_E11_COLD_LATENCY_MS`.** Irrelevant to this comparison's headline numbers but it feeds
  `coldAcquireRate`; on a host where the warm hot-path p50 is 240 ms the shipped 50 ms default
  classifies everything as cold. Derive it from E10 on the same host, as issue #291's
  shakedown did.
- **`SH_E11_VMM_PROC_PATTERN`.** Not used by this arm (no VMM), but scope it before any
  microvm run: the unscoped `firecracker` pattern matched another user's shell on the metal
  box, and under `sudo` a foreign process's PSS would be summed in.

## What the result means

- **`coresBusy` and p95 fall materially at high `c`.** The published `c=8` knee was the
  driver's. §E11's questions become worth asking again, with the backend as the only remaining
  suspect, and a three-arm sweep is worth booking.
- **They do not fall.** `grpcurl`'s per-call cost was not the bottleneck, and that is the
  finding. It points at the closed-loop model — `drivingModel` is still
  `closed-loop-per-slot`, with a declared coordinated-omission bias that understates latency
  at saturation — or at bash's scheduling of `c` subshells, and it says so with a control that
  has no backend.

Either way, record the result in `EXPERIMENTS.md` §E11 and close #294 with the numbers, not
with the code landing.

## One bound worth knowing

The Go client uses **one** connection for a whole rung. Neither server caps concurrent
streams on the pinned versions (grpc-go defaults `maxConcurrentStreams` to `math.MaxUint32`;
`@grpc/grpc-js` leaves Node's http2 default of `4294967295`), so a stream cap is not the
limit. The limit is that one connection has one `loopyWriter` goroutine and one
connection-level flow-control window, so every slot's framing serializes through one writer.
If throughput plateaus while `coresBusy` stays low, shard slots across N connections and run a
third arm — `execClient` is what keeps the three distinguishable.

## Local indicative measurement (not the acceptance comparison)

This machine — a 10-core macOS laptop, no `/proc`, no cgroups — cannot run
`deploy/microvm/e11-density.sh` at all, let alone reproduce the 72-core rig above. What follows
is a smaller, direct comparison of the two Exec clients against the null-responder, run once
during Task 9 of this plan, to prove both clients work and to get a first-order signal before
booking rig time. **It is indicative only and is not the 72-core comparison issue #294's
acceptance criteria name.** No host-CPU measurement was taken, `mix` was reduced to the single
command `true`, and there is no `hostCpuFraction`, `coresBusy` or `hostCpuSamples` in what
follows — only wall-clock Exec throughput.

Both arms issued the **same total Exec count** at each concurrency: `itersPerSlot=18000` plus
`warmupPerSlot=3`, i.e. 18003 Execs per slot. That count was chosen empirically on this
machine, not copied from the brief's illustrative "200" — 200 Execs against the Go client here
complete in well under 200 ms, which is dominated by process and connection startup and shows
nothing. Raising `itersPerSlot` until the `c=1` case (the slowest per-slot rate, since it has
the least concurrency to amortize dial and goroutine setup) cleared roughly 2 seconds of wall
time landed on 18000: 15000 measured 1.821 s, 16000 measured 1.894 s, 17000 measured 2.099 s,
18000 measured 2.169 s. The same 18003-per-slot count was then used, unchanged, for the
`grpcurl` arm.

MEASUREMENT_PENDING_PLACEHOLDER_TABLE_ROW_DO_NOT_COMMIT

The Go client is MEASUREMENT_PENDING_PLACEHOLDER_DO_NOT_COMMIT faster per Exec on this
machine. That gap is expected and is not a substitute for the rig comparison: the
null-responder here answers over loopback with no relay, no proto re-parse cost paid by
anything but `grpcurl` itself, and no contention from 72 cores' worth of other work. It shows
only that the mechanical difference the brief predicts — one persistent connection versus one
`execve` and one fresh HTTP/2 session per Exec — is real and large on this host. Whether it is
what moved the published `c=8` knee on the 72-core rig is exactly the open question this
runbook's rig procedure, above, is for.
