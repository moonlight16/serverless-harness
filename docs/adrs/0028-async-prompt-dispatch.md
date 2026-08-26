# ADR-0028: Async prompt dispatch as a `kind:"prompt"` leaf sharing the `/turn` core

- **Status:** Proposed <!-- Proposed → Accepted → Superseded by ADR-NNNN / Deprecated -->
- **Date:** 2026-08-25
- **Deciders:** Serverless Harness team
- **Spec:** [`../specs/2026-08-25-async-prompt-dispatch-design.md`](../specs/2026-08-25-async-prompt-dispatch-design.md)

## Context

`POST /turn` runs a free-form prompt to completion synchronously, holding an HTTP connection open
for the whole turn. An orchestrator that wants to fire a long-running prompt and collect the answer
later has no path to do so — the exact problem [ADR-0015](0015-async-leaf-completion.md) already
solved for review (`converge`) and patch (`solve`) leaves via the async KEDA queue and `GET
/runs/status`. Issue [#168](https://github.com/rossoctl/serverless-harness/issues/168) asks for a
prompt to ride that same substrate. The maintainer's governing constraint was **cleanest design
over fewest changes**: the answer must reuse existing seams rather than fork the turn path or grow a
parallel one.

## Decision

We will add a third leaf kind, `prompt`, that dispatches a free-form prompt over the **existing**
run-envelope / KEDA / result-record substrate — no new queue, worker, scaler, route, or status
endpoint. Its result is a **dedicated** `LeafResult` discriminant `{ status:"responded"; text }`
(mirroring `solved`/`patch`), not an overload of `done`. To give the leaf **full `/turn` parity**,
we will factor `runTurn`'s middle into a shared internal `executeTurn(...)` core that both `/turn`
and `runPromptLeaf` call, parameterized only by session-open policy (`createIfAbsent`) — `false`
preserves `/turn`'s 404-on-missing-session contract, `true` gives the leaf create-or-resume. The
leaf resolves the model with the leaf-family precedence (`env.model ?? config?.model → SH_MODEL →
default`) and inherits `/turn`'s `resolveSandboxConfig` sandbox routing.

### Alternatives considered

- **Reuse `done` + a text field for the result** — breaks the union's one-discriminant→one-payload invariant and forces every `done` consumer to disambiguate a verdict from text; `responded`/`text` is the clean fit.
- **A restricted / tool-gated prompt variant** — diverges from `/turn` behavior; parity via a shared core is simpler and drift-free.
- **A second copy of `runTurn`'s wiring for the leaf** — two extension stacks that inevitably drift; extract-and-share keeps one source of truth.
- **Solve's `selectPoolSandbox` lease for prompt leaves** — imports the saturation/503 path and breaks the "identical sync or async" promise; prompt leaves use `/turn`'s sandbox resolution instead.

## Consequences

- Positive: a prompt behaves identically sync (`/turn`, `async:false`) or async (`async:true`) because it runs the *same* code; the `/runs` route, job runner, and KEDA `ScaledJob` are unchanged; prompt leaves inherit async resumability for free from the durable session log.
- Negative / accepted cost: prompt leaves get no per-leaf pool isolation (they share `/turn`'s sandbox model), so a fleet of async prompts is not lease-bounded the way solve leaves are; `runTurn` is refactored, so its behavior is now pinned by a regression test rather than by being the only caller. A prompt leaf may still be addressed to a `workloadId` (the workload gates existence and returns 404 if absent), but its pool selector is intentionally ignored — the API boundary logs a warning rather than injecting a selector that `executeTurn` would silently drop.
- Follow-up owed: pool-based isolation (a `selectPoolSandbox` lease) for prompt leaves, deferred until a driver needs it; extend `deploy/knative/leaf-async-smoke.sh` with a `responded` claim.

---

*Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>*
