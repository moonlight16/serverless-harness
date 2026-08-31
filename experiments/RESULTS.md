# M6 Experiment Results

## E2 — local reconstruction cost (openFromCheckpoint vs openFromBackend)

Synthetic sessions, each compacted once with a fixed kept tail. Metric = entries + bytes
returned by `backend.read()` during reconstruction (the slice each loader rebuilds from).
`*` ms columns are wall-clock on a dev box — **illustrative only**; the gate is the
deterministic entries ratio. `backend bytes` is environment-sensitive too (it differs
between CI and a dev box), so the committed copy of this file is compared on the entries
and ratio columns only.

This file is a **committed baseline**: `e2-reconstruction-cost.test.ts` asserts that a fresh
run still matches those columns, and writes each run's own table to the gitignored
`experiments/.results/`. Refresh it deliberately when a change legitimately moves the read
counts: `SH_E2_UPDATE_BASELINE=1 pnpm -C experiments test e2-reconstruction-cost`.

| N (session len) | backend entries | checkpoint entries | ratio (b/c) | backend bytes | checkpoint bytes | backend ms* | checkpoint ms* |
|---|---|---|---|---|---|---|---|
| 50 | 53 | 6 | 8.8 | 7482 | 896 | 0.9 | 1.2 |
| 200 | 203 | 6 | 33.8 | 28508 | 901 | 2.1 | 3.2 |
| 1000 | 1003 | 6 | 167.2 | 140908 | 901 | 4.8 | 5.1 |
| 5000 | 5003 | 6 | 833.8 | 706909 | 906 | 23.5 | 20.0 |

**Pass:** checkpoint entries stay ~constant (bounded by the kept tail) while backend entries
grow linearly with N, so the backend/checkpoint ratio strictly increases with N. `buildSessionContext()`
is identical under both loaders at every N.

## E5 — budget-voter enforcement

Verified by `e5-budget-structural.test.ts` (no key, real Redis): once per-turn spend exceeds
`SH_BUDGET_TOKENS`, the `tool_call` is blocked and exactly one `abort` entry is persisted;
with the cap unset the voter is inert (no block, no `abort`). A key-gated live run
(`e5-budget-live.test.ts`, tiny cap) confirms the same end-to-end with a real model. See
`README.md` for how to run the live variant.

*Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>*
