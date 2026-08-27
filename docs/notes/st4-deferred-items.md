# ST4 worker — known-and-deferred items at merge time

Recorded from the implementation ledger. Nothing here affects the acceptance
battery or runtime correctness; all were seen, judged, and deliberately not fixed.

## Recommended before merge (3)

- Task 5: minor (deferred, RECOMMEND FIXING BEFORE MERGE): Fingerprint's 0x00 separator is not injective if `command` itself contains a NUL — Fingerprint("a\x00b", nil) and Fingerprint("a", []byte("b\x00")) collide. Low practical risk (proto3 strings may carry NUL but such a command could not exec), but a collision in the guard means a silent wrong answer, which is the exact failure class the guard exists to prevent. A length-prefix would close it (~3 lines).
- Task 10: minor (deferred, RECOMMEND FIXING BEFORE MERGE): backoff resets on TRANSPORT success (client.Attach returning a stream), not session success. With a persistently wrong SANDBOX_TOKEN the relay accepts the HTTP/2 stream then rejects the session, so the loop re-enters the err==nil branch every cycle and retries at the ~500-750ms floor forever, never growing. Not hot-spinning (there is always a jitter wait) so it is Minor by the rubric, but a misconfigured worker hammering a relay twice a second indefinitely is a real operational nuisance, and wrong-token is a common misconfiguration. Plan-mandated: my brief's reference code has the identical reset condition. Fix: reset only after a session that stayed up beyond a threshold.
- Task 10: minor (deferred, RECOMMEND FIXING BEFORE MERGE): nothing in CI protects the attachCtx-derivation property. A future edit swapping attachCtx for context.Background() at either call site would compile and pass gofmt/vet/tests, surfacing only as a production shutdown hang. Currently guarded solely by the implementer's manual SIGTERM runs.

## Parked residuals from the final whole-branch review (6)

Ruling: R39 — all six residuals PARKED, no second fix wave (process allows one). Three are worth 
the user's attention before merge and go in the PR body: (1) DM3's "either direction" prose clause 
is still inaccurate — Serve←Background with a cancelled stream ctx shuts down cleanly, verified 
twice, so only the second clause is true; (2) EM7's non-streaming contract test PASSES even when 
the worker ignores streaming:false entirely — the FOURTH test-that-cannot-fail on this branch, 
closable with `cat file; sleep 1` plus a first-chunk-arrival assertion; (3) the ST4 design spec now 
drifts from shipped code (it says a collider "runs fresh", but an in-flight collider is refused; 
and its "cache consulted before enqueue" line omits the in-flight check that now precedes it) — 
DESIGN.md and the findings note were updated, the spec was not. The other three (memory coupling 
documented-not-enforced, D6's by-design dropped-refusal residual, settle()'s fixed sleep) ship 
as-is. Cost if wrong: three Low-severity items reach the PR as known-and-recorded rather than 
fixed; none affects runtime correctness.

## Deferred minor findings (33)

- Task 1: minor (deferred): remote-worker/Dockerfile lost a blank line before the final FROM — unrequested cosmetic drive-by, harmless.
- Task 2: minor (deferred): no //go:build unix constraint — syscall.Setpgid/Kill break a Windows build with a compile error rather than a clear message.
- Task 2: minor (deferred): drain swallows ALL read errors, so a genuine EIO silently truncates output while Run still reports exit 0.
- Task 2: minor (deferred): stdin writer can block on a >64 KiB payload a command never reads; its goroutine lifetime is tied to Wait.
- Task 2: minor (deferred): Sink doc "data is owned by the callee" is ambiguous about retention vs mutation.
- Task 2: minor (deferred): chunk-cap test depends on head/tr//dev/zero; printf would be hermetic on minimal images.
- Task 2: minor (deferred): Spec.ReqID unread in-package (exists for caller frame correlation) — worth a note against future "unused field" cleanup.
- Task 2: minor (deferred): spec §5's terminal-frame table omits the duplicate-in-flight ExecError that Task 6 emits.
- Task 2: minor (deferred): drain-watchdog grace is wall-clock from runCtx.Done(), not activity-based — a slow-but-not-wedged drain after a timeout could force-close between reads and drop legitimate trailing output. Narrow (the run is already out of budget) and it is the remedy shape the review itself proposed; resetting the timer on read/sink activity would close it.
- Task 3: minor (deferred): the base64 test's doc comment writes the harness shape as `base64 -d > 'path'` (quoted) while the command built is unquoted; cosmetic, and t.TempDir() paths contain no metacharacters.
- Task 4: minor (deferred): TestAbortViaContext's Run has neither a deadline nor Spec.TimeoutS, so it does not literally satisfy the standing bounded-execution rule; no real hang exposure (bash -c "sleep 30" self-exits at 30s, well inside go test's 10-minute budget).
- Task 4: minor (deferred): the grandchild test's 500ms pre-abort sleep and 1s observation window are tight versus other margins in the file; the `if first == 0` guard converts extreme-load slowness into a loud failure rather than a silent pass, so the risk is a rare false flake, not a false negative.
- Task 5: minor (deferred): Put/Lookup share the *pb.WorkerFrame pointer with no defensive copy — a caller mutating a frame after handoff silently corrupts the cached entry. Inherent to the brief-mandated signature; carried into Task 6's dispatch as an explicit immutability requirement instead.
- Task 5: minor (deferred): Put's overwrite branch (same req_id twice → update fingerprint + refresh recency) is unexercised by any test, though it is exactly the collision-recovery path.
- Task 5: minor (deferred): NewCache's non-positive-max fallback to CacheSize is untested.
- Task 6: minor (deferred): a signalled exit (code -1 with the run ctx still live, e.g. OOM-kill) is cached as End{-1}, which the file's own comment says it avoids for aborts; defensible but the comment should say so or the code should decline to cache code < 0.
- Task 6: minor (deferred): Fingerprint excludes TimeoutS, so a redelivery of the same command with a larger budget re-emits a stale "timeout:30" — the message then misstates what was asked.
- Task 6: minor (deferred): close(queue) precedes cancelConn(), leaving a window where a pool goroutine dequeues an uncancelled slot and spawns a real bash child that is killed immediately; cancelling first avoids the pointless spawn.
- Task 6: minor (deferred): MaxConcurrent has no ceiling and is truncated by uint32() when advertised as capacity_max, so a misconfigured value makes Hello dishonest.
- Task 6: minor (deferred): inconsistent state plumbing — abortReq/finish close over inflight/mu while accept takes the map and *sync.Mutex as parameters; one convention would make "every access is under mu" locally checkable.
- Task 6: minor (deferred): the fix report overstates termination — producers block on `outbound <-`, so reaching zero requires the sender to dequeue, which requires the in-progress st.Send to return. No realistic wedge (teardown starts only after Recv errored, when SendMsg returns promptly), but a future reader may rely on the stronger claim.
- Task 6: minor (deferred): trySend can drop a TERMINAL frame on the cache-hit path, not merely an advisory one, when outbound (cap 64) is full — recoverable, since the cache retains it, but the code comment says "advisory frame" and understates it.
- Task 6: minor (deferred): internal/exec's Sink contract is now load-bearing beyond what it documents — with Chunk writing to a channel Serve closes, any Runner calling Chunk after Run returned would panic rather than get an error. BashRunner does not (its pumps are joined before Run returns) and no other implementation exists, but the doc forbids only CONCURRENT calls, not post-Run ones.
- Task 7: minor (deferred): TestAbortUnknownReqIDIsNoOp (100ms) and TestDuplicateInFlightIsCoalesced (200ms) use fixed sleeps to prove a negative; standard for the pattern but they are additional timing dependencies beyond the 50ms settle.
- Task 7: minor (deferred): the report's per-test analysis claims all eight tests would fail on regression without qualification; item 7 does not hold up and is corrected by R26.
- Task 8: minor (deferred): Collect and the manual grep loop have per-frame 15s deadlines but no overall test deadline — a defect emitting an endless stream of near-immediate non-matching frames would run long before any individual timeout, falling back on go test's global timeout rather than a named failure.
- Task 8: minor (deferred): commit 0c5648b's message says "a ~60 KiB grep proving the chunk cap" — stale by >2x versus the corrected 149 KiB. Cannot be amended (git commit --amend denied by user settings, see R14); reword at rebase/squash if desired.
- Task 9: minor (deferred): Collect's per-frame 15s timeout means a worker that hung after Abort without sending a terminal frame would block ~15s before failing — satisfies the bounded-deadline bar, but the worst-case runtime is far above the observed ~1s.
- Task 9: minor (deferred): the live test's fixed 500ms sleep to let the relay park the stream is a timing assumption, not a handshake — the one place a real operator could hit spurious friction on first use against a loaded relay.
- Task 10: minor (deferred): envInt has no upper bound, so an absurd WORKER_MAX_CONCURRENT could misreport capacity_max via the uint32 cast in Hello. Plan-mandated; would exhaust memory before the wrap mattered.
- Task 10: minor (deferred): TestEnvIntFallsBackOnGarbage covers "0" but not a negative value, though both hit the same `v <= 0` comparison.
- Task 11: minor (deferred): both images install findutils, which none of the harness's ops need; from my brief's snippet, harmless, and DESIGN.md's "carries bash, base64, and file" bullet does not mention it.
- Task 12: minor (deferred): findings doc cites relay.ts:105-125 for routeExec, which actually starts at 104 — off by one, mechanism described correctly.
