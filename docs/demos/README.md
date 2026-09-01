# Demos — guided walkthroughs

Hands-on tours you **drive by hand**, one command at a time, explaining as you go. Each one shows
something a conventional setup cannot do, and is structured in *acts* so it survives being
performed live in front of an audience.

## What lives here

| Demo | Shows | Time |
|------|-------|------|
| [`serverless-harness-demo.md`](./serverless-harness-demo.md) | An agent that **scales to a true zero**, resumes from cold with full memory, then **fans out into a worker fleet** that appears on demand and vanishes when the queue drains | ~10 min |
| [`remote-sandbox-demo.md`](./remote-sandbox-demo.md) | A **sandbox outside the cluster** with zero inbound rules, executing a leaf's tool calls — same request, opposite verdicts, and a secret planted by hand that the cluster reads back | ~10 min |

## Demo vs. smoke test vs. spec

These three overlap and are easy to confuse:

- **A demo (here)** is *performed*. It optimizes for a human explaining a claim out loud, so it
  narrates why each step matters and deliberately pauses on the moments that are hard to believe.
  Every command is copy-pasteable.
- **A smoke test** ([`../../deploy/knative/SMOKE.md`](../../deploy/knative/SMOKE.md)) is *asserted*.
  It optimizes for an unattended pass/fail with no narration. Most demos here have a scripted
  sibling — `remote-sandbox-demo.md` is `make demo-remote-sandbox`, and Act 2 of
  `serverless-harness-demo.md` is `leaf-async-smoke.sh`. Prefer the script when you want a verdict;
  prefer the demo when you want to *convince someone*.
- **A spec or ADR** ([`../specs/`](../specs/), [`../adrs/`](../adrs/)) records the ***why*** — the
  decision and its rejected alternatives. A demo shows the *what*, and goes stale when the
  commands change; a decision record does not.

## Conventions

If you add a demo, follow the shape of the two above:

- **Open with the claim**, then a table of "what the normal thing needs / what this needs". A reader
  should know in fifteen seconds whether this demo is the one they want.
- **Acts, with lettered sub-steps** (`### 1a.`, `### 1b.`) so you can resume mid-performance and so
  a reviewer can cite a step.
- **Blockquote callouts (`>`) for the narration** — what to *say*, and which traps the step defends
  against. Keep them out of the code blocks so the commands stay copy-pasteable.
- **Show expected output** inline. A demo whose output you cannot compare against is a demo that
  has silently rotted.
- **End with "What just happened"** (recap the claims, numbered) and **"Cleanup"** (leave the
  cluster as you found it — restore any env you flipped *first*).
- **Be honest about limits.** A closing "Notes and limits" section naming what the demo does *not*
  show is worth more than an extra act, because it is what stops someone over-promising in a room.
