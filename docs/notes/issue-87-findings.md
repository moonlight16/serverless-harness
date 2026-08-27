## ST4 findings — four discrepancies worth other tracks' attention

Surfaced while implementing the reference worker in `remote-worker/` against
§3/§4/§6/§7 of the design. Design doc:
`docs/specs/2026-08-26-st4-go-reference-worker-design.md`.

### 1. `req_id` is not unique per worker (affects ST1/ST3)

`harness/src/select-sandbox.ts:60` deliberately shares sandboxes ("pick
least-loaded under the soft cap"). Each leaf builds its own
`GrpcRelayTransport` for the same `sandbox_id`, and
`packages/k8s-sandbox/src/grpc-relay-transport.ts:22` seeds `reqCounter = 0`
at **module scope** — per harness process. Knative scales the harness to
multiple replicas, and the relay (`packages/sandbox-relay/src/relay.ts`)
multiplexes all of them onto the one Attach stream it keeps per `sandbox_id`
(one `Parked` entry per sandbox, `reqId`-keyed sinks registered onto it —
`relay.ts:105-125`), so replica A and replica B both send `req_id: 1, 2, 3…`
to the same worker.

A `req_id`-keyed dedup cache would therefore answer replica B's `cat /a` with
the cached terminal frame from replica A's unrelated command — a silent wrong
result.

**Worker-side mitigation (shipped):** the cache
(`remote-worker/internal/session/cache.go`) compares a SHA-256 fingerprint of
`command`+`stdin` as well as `req_id` (`Fingerprint`, `cache.go:15`). A
genuine redelivery is byte-identical and re-emits the cached frame; a
collision has a different fingerprint, runs fresh, and logs a warning
(`internal/session/loop.go`'s `accept`, the `collision` branch). The same
fingerprint is also carried on the in-flight slot, which is where the collision
window is widest: while the original is still running the cache cannot see it at
all, so a matching fingerprint is coalesced as a redelivery and a mismatching one
is refused with an `ExecError` rather than silently swallowed.

**Proposed real fix:** make `req_id` globally unique — a random 64-bit seed
per transport instance, or a replica-scoped prefix. The worker guard is
defense-in-depth, not a substitute.

Worth noting the hazard the dedup cache was built for does not exist yet: the
relay never redelivers (it fails in-flight execs on stream close with
`{ error: { reqId, message: "worker disconnected" } }`,
`relay.ts:87-98`) and the harness never retries a `req_id`.

### 2. §7's non-streaming shape is not expressible in `sandbox/v1` (doc fix)

§7 and §8 of the parent spec say non-streaming ops return "a single `End`
carrying full stdout", but the wire message is
`message End { uint64 req_id = 1; sint32 exit_code = 2; }`
(`proto/sandbox/v1/sandbox.proto:67`) — there is no data field to carry
output on. `GrpcRelayTransport.exec` also always sends `streaming: true`
regardless of caller intent (`grpc-relay-transport.ts:51`), so the flag is
currently dead on the wire in both directions.

The worker honors the flag's observable intent — no incremental delivery
while the process is running — without inventing a new field: for
`streaming: false` it buffers stdout/stderr until the process exits, then
emits them as `Chunk` frames capped at `ChunkSize` (32 KiB,
`internal/exec/runner.go:24`) per stream. Small output still round-trips as
exactly one `Chunk` per stream; output larger than the cap goes out as
several `Chunk`s in that same post-exit burst, since a single frame must stay
under the wire's 32 KiB cap regardless of the streaming flag
(`internal/exec/runner.go`'s `emitBuffered`, exercised by
`TestNonStreamingChunksAtExit` and `TestNonStreamingSmallOutputIsOneChunkPerStream`
in `internal/exec/runner_test.go`). Adding `bytes stdout` to `End` was
rejected: it changes a published contract other tracks build against, for a
field the harness never reads, and creates two ways to return the same
bytes. Suggest correcting the prose in the parent spec to describe delivery
timing ("all at once, after exit") rather than frame shape ("a single `End`
carrying stdout").

### 3. Neither worker image had a shell (fixed here)

`remote-worker/Dockerfile` built its final stage on
`gcr.io/distroless/static-debian12:nonroot`, and `remote-worker/Dockerfile.runtime`
on `registry.access.redhat.com/ubi9/ubi-micro:latest`. Once the worker
actually runs `bash -c <command>` per exec, **every exec would fail with
ENOENT** in those images. Both now use
`registry.access.redhat.com/ubi9/ubi-minimal:latest` with `bash`,
`coreutils-single` (`base64`, used by `writeFile`), `findutils`, and `file`
(image MIME sniffing) installed via `microdnf`. Both images were built and
run (verified on the change that swapped the base, not repeated for this
write-up) to confirm `bash`, `base64`, and `file` are present and that the
non-root `USER 1001` takes effect.

This does not weaken "static binary, no runtime deps": the build stage still
runs `CGO_ENABLED=0 go build` (`remote-worker/Dockerfile`), so the binary
itself stays CGO-free and statically linked. `bash` is a dependency of the
*commands* the worker execs, not of the worker binary. In production the
binary drops into a sandbox image that already has a shell — it is the two
standalone demo images (built directly from this repo, not from a sandbox
image) that needed the base swap.

### 4. A cache hit re-emits only the terminal frame, never the output chunks (contract gap)

The dedup cache (`internal/session/cache.go`) stores exactly one
`*pb.WorkerFrame` per `req_id` — the terminal frame (`End` or `ExecError`)
that `runOne` produced the first time. On a redelivery, `accept` in
`internal/session/loop.go` looks the frame up and sends it straight back
(`trySend(frame)`) without ever calling `runOne` again — so no `Chunk`
frames are re-emitted, because none were ever cached. A redelivered
*streaming* exec therefore returns its correct exit code with **zero
output**. For `cat file` that means `End{exit_code: 0}` with no `Chunk` ever
sent — the caller sees a successful exit and empty content, a silently
wrong answer.

The worker is spec-compliant here: the design's own dedup table says a
fingerprint match should "re-emit cached terminal frame, do not run"
(§6.3), and `End` has nowhere to put output even if the worker wanted to
resend it (see finding 2 — `End` carries only `req_id` and `exit_code`). So
the gap is in the contract, not in this implementation.

**Why it is not a real bug today:** it is unreachable — nothing in the
system redelivers a `req_id` (see finding 1's last paragraph: the relay
fails in-flight execs rather than replaying them, and the harness does not
retry). It is listed here anyway because it is the same class of problem as
finding 1: both are latent consequences of dedup being specified only in
terms of `req_id` and a terminal frame, with no accounting for what a
*streaming* exec's redelivery should return.

**Proposed real fix:** if redelivery becomes reachable (e.g. a future
retrying relay), the contract needs either (a) an explicit statement that a
cache hit answers with the terminal frame only and callers must not expect
output on a redelivered streaming exec, or (b) a cache that also replays
buffered `Chunk`s, which requires bounding how much output a cache entry may
hold. Today's worker takes the cheapest correct-by-contract option: it does
exactly what the spec says and nothing more.

_Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>_
