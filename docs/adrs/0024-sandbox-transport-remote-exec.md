# ADR-0024: Remote sandbox exec over a worker-dialed gRPC stream, contract as language-neutral Protobuf

- **Status:** Accepted
- **Date:** 2026-07-08
- **Deciders:** Serverless Harness team
- **Spec:** [`../specs/2026-07-08-sandbox-transport-grpc-design.md`](../specs/2026-07-08-sandbox-transport-grpc-design.md)

## Context

The harness runs every Pi tool call inside a sandbox pod via `kubectl exec`, so it must dial *into* the pod through the kube API. That rules out any sandbox behind NAT, on-prem, on a laptop, or in another cloud — and blocks the top driver, bring-your-own (untrusted third-party) sandboxes. Reaching those requires inverting connectivity (the sandbox dials *out*) with a contract that is language-neutral (any runtime can host a worker) and firewall-friendly (one outbound TLS connection on `:443`), without touching the Pi loop, the session backend, or the leaf queue. An earlier revision of this PR got the outbound-dial direction right but carried the RPC over Redis Streams behind a TypeScript interface — locking workers to TS via JSON+base64 frames and forcing Redis (a port `:443`-only egress commonly blocks) into the exec path.

## Decision

We will delegate remote command execution over a single **worker-dialed gRPC bidirectional `Attach` stream (HTTP/2 on `:443`)**, define the contract as a **Protobuf IDL (`sandbox/v1`)** rather than a language-specific interface, and land both paths behind the existing **`SandboxTransport`** seam — `KubectlTransport` (today's in-cluster fast path, renamed) and a new `GrpcRelayTransport` are two implementations of one interface. A **single-replica, presence-only** in-cluster relay bridges the worker's outbound stream to the harness's in-cluster `SandboxExec` calls and mirrors connected workers into the existing Redis sandbox pool; matching stays in `select-sandbox`. One **Go reference worker** ships as the honest proof the contract is genuinely language-neutral.

### Alternatives considered

- **Redis-Streams transport + TS `@sh/sandbox-worker`** (this PR's prior revision) — rejected: TS lock-in through JSON+base64 frames, and Redis-on-its-port is blocked by `:443`-only egress while forcing a Redis dependency into exec.
- **Connect / HTTP-1.1 fallback** — rejected: full-duplex bidi needs HTTP/2 regardless, so Connect adds a second toolchain for no gain on the streaming core.
- **Relay owning matching / multi-replica HA** — deferred: a single replica needs no presence glue beyond the pool mirror, and matching stays in the existing pool.

## Consequences

- Positive: a sandbox can live anywhere behind one outbound `:443` connection with no inbound rules; any gRPC-capable language can host a worker; the in-cluster `kubectl-exec` path is unchanged; everything above `select-sandbox` stays transport-blind; the frame semantics (`req_id` correlation, at-least-once + dedup, dual-ended timeout, per-exec output cap) carry over verbatim.
- Negative / accepted cost: a new in-cluster relay component plus a Protobuf/gRPC toolchain; single-replica relay means a restart drops all parked streams and fails in-flight execs (recovery is leaf retry — no mid-exec durability); exactly-once is impossible — at-least-once + dedup only, with partial-write risk on crash.
- Follow-up owed: untrusted-BYO SPIFFE/mTLS on the same `Attach` endpoint; multi-replica relay HA; private-mesh reachability (Headscale / WireGuard); additional-language workers; HTTP/1.1-only proxy traversal — all additive behind the same seam.

## Revisions

### 2026-08-28 — `req_id` uniqueness (issue #179)

The original decision left `req_id` as "monotonic", which was implemented as a
module-scope counter — per process. `select-sandbox` shares a sandbox across replicas by
design (`max-scale: 5`, lease cap 20), and the relay keys per-exec sinks by `req_id`
within a session, so two replicas emitting `1, 2, 3…` could silently detach one caller
(it hangs to its deadline) and interleave both execs' output into the other.

**Decided:** ids carry a 21-bit per-process random salt in the high bits and a 32-bit
counter in the low bits. The maximum reachable id is `(2^21 − 1)·2^32 + (2^32 − 1) =
9007199254740991`, exactly `Number.MAX_SAFE_INTEGER` — required because the generated
TypeScript maps `uint64` through `longToNumber`. That is zero headroom, not a margin: the
layout lands precisely on the boundary, so widening the salt to 22 bits or the counter to
33 does not consume slack — it immediately crosses into precision loss and silent id
aliasing, where two different execs collapse onto one number. Uniqueness is probabilistic
in the salt (birthday collision ≈ 4.8e-6 across five replicas — `C(5,2)/2^21`) and exact in
the counter.

**Rejected:** widening the generated mapping to `string`/`Long` with a UUID — correct but
it reopens the `sandbox/v1` contract and the Go worker's cache key for a failure mode the
salt already closes. Also rejected: caller-scoped correlation at the relay
(`(callerId, reqId)`), which needs a proto field and leaves the worker's dedup cache still
keyed on a non-unique id.

**Consequence:** the relay now rejects a duplicate in-flight `req_id` rather than
overwriting the live sink, converting a silent misroute into a loud error.

### 2026-08-28 — the output cap moves onto the seam, but covers two of three transports

§8 always worded the cap as a harness-level property, but only `GrpcRelayTransport`
implemented it; `KubectlTransport` buffered without bound behind a `TODO(M3)`.

**Decided:** both **per-call** transports enforce it, the constant and marker live on the
seam (`transport.ts`), and the shared conformance battery asserts it for both — because a
cap on one implementation makes the transports distinguishable to Pi, which contradicts the
swappability the epic's driver #2 claims.

**Still not a seam-wide guarantee.** There is a third `SandboxTransport`,
`persistentExecInPod`, and it remains uncapped; `extension.ts` gives it
Read/Write/Edit/Ls/Find, so the file-reading tools are exactly the ones running without a
cap. The battery therefore covers two of three implementations, and Pi can still tell the
backends apart on output volume. Capping the Read path is a production behaviour change and is tracked
separately. What *is* closed here is the damaging consequence: because that transport falls
back to the capped `KubectlTransport` on channel death, a truncated read could reach Pi's
Edit tool and be written back over the file, so `createPodReadOps.readFile` now throws
instead of returning bytes it cannot vouch for.

---

*Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>*
