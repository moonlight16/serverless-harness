# @sh/experiments — M6 experiments (E2 + E5)

In-process experiment runners for the serverless-harness. See
`docs/specs/2026-06-24-m6-experiments-design.md`.

## Prerequisites

```bash
docker run -d --rm --name sh-m6-redis -p 6379:6379 redis:7-alpine
```

## E2 + E5 structural (no LLM key — the pass gate)

```bash
pnpm -C experiments test
```

- E2 asserts the checkpoint/backend read ratio grows with session length, writes each
  run's measured table to the gitignored `experiments/.results/RESULTS.md`, and checks the
  reproducible columns against the committed baseline in `experiments/RESULTS.md`.
- E5 structural asserts the voter blocks + persists exactly one `abort` over cap,
  and is inert when the cap is disabled.

### The E2 baseline

`experiments/RESULTS.md` is committed and is **not** rewritten by a test run — that used to
leave the working tree dirty with machine-local timings after any `pnpm -r test`. A run now
writes its own table to the gitignored `experiments/.results/` and compares only the columns
that reproduce anywhere:

| Column | Compared? | Why |
|---|---|---|
| `N`, backend/checkpoint entries, ratio | yes | deterministic — identical on CI and a dev box |
| `backend bytes` | no | environment-sensitive (measured +4 bytes on CI) |
| `checkpoint bytes` | no | same class as `backend bytes` |
| `backend ms`, `checkpoint ms` | no | wall-clock; varies run to run |

So a change that moves the read counts fails E2 instead of silently rewriting the recorded
result. When the move is legitimate, refresh the baseline deliberately and commit it:

```bash
SH_E2_UPDATE_BASELINE=1 pnpm -C experiments test e2-reconstruction-cost
```

`SH_E2_RESULTS_DIR=<dir>` redirects the per-run copy elsewhere.

## E5 live (real model — manual, end-to-end)

Model + provider + credentials are runtime inputs; no secrets live in the repo.

```bash
export SH_MODEL_PROVIDER=anthropic
export SH_MODEL=claude-opus-4-8
export ANTHROPIC_AUTH_TOKEN=…              # (+ ANTHROPIC_BASE_URL=… for the litellm gateway)
export SH_RUN_LIVE=1 SH_BUDGET_TOKENS=1
pnpm -C experiments test e5-budget-live
```

### Tools (so the model has something to call)

The live run needs at least one registered tool so a `tool_call` fires and trips the
tiny cap. If the harness registers no tools without a sandbox, set
`KAGENTI_SANDBOX_POD=<pod>` (M2 sandbox) before running, or adjust the prompt to target
whatever built-in tool the `DefaultResourceLoader` exposes. The live run is **not** the
pass gate (the structural test is); it is the end-to-end confirmation.
