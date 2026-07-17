# Shared Agent Context in serverless-harness via IBM Storage Scale

Slide-deck planning doc (Markdown outline → PowerPoint). Local/fork-only while in draft;
not part of the upstream `kagenti/serverless-harness` docs tree.

Status: DRAFT — phases 1–2 in progress on `agentic-cloud`; phases 3+ not started.

---

## Slide 1 — Title

**Shared Agent Context in serverless-harness, via IBM Storage Scale**
Establishing the foundation for persistent, shareable agent state — and evaluating
IBM Storage Scale (GPFS) as the storage layer.

---

## Slide 2 — Goal

> We want to share agent context in serverless-harness using IBM Storage Scale.
> Establish the foundation for persistent, shareable agent state, and evaluate the
> value of IBM Storage Scale as the storage layer.

Two threads, deliberately separated:
1. **Mechanism** — can sandboxes share a filesystem at all, safely, under real load?
2. **Value** — once they can, what does a shared, persistent, POSIX filesystem actually
   buy an agent fleet that per-pod storage doesn't?

---

## Slide 3 — Why this matters (framing, not yet answered)

- Today's harness architecture (P1/P2, shipped) deliberately chose **per-sandbox RWO** —
  no shared filesystem, no cross-pod state. That was the *right* call for a first cut:
  it minimizes contention risk and runs on any CSI (EBS, etc).
- But "no shared state" is also a ceiling: agents can't hand off a workspace, can't
  build on each other's partial results, can't be given a durable/persistent memory that
  outlives a single sandbox pod.
- IBM Storage Scale (GPFS) is a real, mature, POSIX-compliant, RWX-capable, multi-protocol
  (also S3-via-AFM) clustered filesystem — it's a plausible foundation for that shared
  state, if the concurrency model holds up.

---

## Slide 4 — Phased plan

| Phase | What | Status |
|---|---|---|
| 1 | Multi-sandbox pool spread across nodes, **1 PVC per sandbox** (not shared) | ✅ done (node-spread via `topologySpreadConstraints`, upstream PR #134) |
| 2 | **Shared RWX PVC** on `ibm-scale-csi`, all sandboxes mount one `/workspace` | 🚧 in progress — PVC bound, pods Ready, shared-mount proven; BugStone Act 2 correctness validation surfaced a contention/queue issue under investigation |
| 3 | Run **BugStone** and **SWE-agent** workloads against the shared-PVC config | 🚧 BugStone Act 1 (sync) passing; Act 2 (async/parallel) surfaced an issue — see Slide 7 |
| 4 | **Read-only fileset/filesystem** for shared, immutable content (GPFS supports RO filesets) — targeted fix for cross-pod write contention | ⬜ not started |
| 5 | **AFM-to-S3**: use GPFS AFM to tier/replicate agent results out to S3-compatible storage | ⬜ not started |
| 6 | Investigate **git repos for BugStone/SWE-bench on GPFS** directly (vs. today's `gitd` distribution service) | ⬜ not started, open question |
| 7 | **Demo** — TBD content, showing the concrete benefit of GPFS as the storage layer | ⬜ not started |

---

## Slide 5 — Phase 1 recap: multi-sandbox, per-sandbox PVC (done)

- 3 `Sandbox` CRs (`sandbox-0/1/2`), each with its own RWO `volumeClaimTemplate`.
- `topologySpreadConstraints` (maxSkew 1, `whenUnsatisfiable: ScheduleAnyway`) spreads them
  across 3 distinct nodes — confirmed live (`agentic-node-1/2/3`).
- This is the shipped P2 design's decision (`docs/specs/2026-07-02-p2-shared-sandbox-pool-design.md`
  §D1): per-sandbox RWO, no RWX on the deployable path, explicitly to avoid cross-pod
  fetch/worktree contention.
- **This phase is the baseline we're deliberately deviating from in Phase 2.**

---

## Slide 6 — Phase 2: shared RWX PVC on GPFS

- One `ibm-scale-csi` (GPFS) PVC, `ReadWriteMany`, mounted at `/workspace` by all pool
  sandboxes — replacing the 3× per-sandbox RWO PVCs.
- `agent-sandbox` v0.5.0's controller only mutates `.Volumes` to merge in
  `volumeClaimTemplates`-derived volumes — omit `volumeClaimTemplates`, supply a plain
  `volumes:` block with a `persistentVolumeClaim` ref, and it passes straight through.
  No controller changes needed.
- **Proven so far:** PVC provisions fast (5Gi RWX bound in ~2s), all 3 pods mount it and
  go Ready, a file written from `sandbox-0` is immediately visible from `sandbox-1`/`sandbox-2`
  — genuine shared POSIX filesystem, not per-pod copies.
- **The open risk, called out explicitly in the design doc's own header comment:**
  `harness/src/converge.ts` uses one shared object store (`/workspace/repo`) + one fixed
  lock (`/workspace/.sh-fetch.lock`) via `flock`. That was written assuming a per-pod FS;
  under one shared PVC it becomes a **cross-pod lock on a shared git repo**. `flock` is
  POSIX-correct cross-pod on GPFS in theory — this needed a real concurrent workload to
  validate, which is exactly what Phase 3 is for.

---

## Slide 7 — Phase 3: BugStone / SWE-agent correctness validation

- **Act 1 (sync, one leaf at a time):** passed cleanly on the shared-RWX config —
  7/7 succeeded, `audit_passed: true`, no converge/lock errors.
- **Act 2 (async, KEDA-scaled parallel leaves — the actual concurrency stress test):**
  failed both runs so far. Investigation in progress; **current evidence points away from
  the GPFS/flock contention risk and toward an unrelated, pre-existing harness bug**:
  - Leaves get stuck in `queued`/`pending` and never resolve.
  - Redis Streams inspection shows the underlying leaf-worker message was delivered to a
    consumer, but never ACKed — the worker pod is gone (scaled to zero) and the message is
    now permanently orphaned in the pending list (no `XCLAIM`/reclaim logic observed).
  - The stuck session's own event log shows the model calling `submit_verdict` **~1,269
    times** in a single session — a runaway tool-call loop, not a filesystem or lock error.
    Zero converge/git/worktree error signatures in any stuck run.
  - Working theory: the turn loop has no "stop after a session-ending tool call" logic,
    so it runs until an external timeout kills the pod — independent of storage backend.
    Under investigation; this slide will be updated with the confirmed root cause and
    whether it reproduces identically on plain RWO.
- **So far, nothing here implicates GPFS or the shared PVC specifically** — but Phase 3
  isn't signed off until Act 2 passes clean and/or the bug is confirmed storage-independent.

---

## Slide 8 — Phase 4: read-only fileset/filesystem for contention

- GPFS supports **read-only filesets** (and read-only whole filesystems) as a first-class
  feature — independent of any application-level locking.
- Hypothesis: most cross-pod contention in an agent-sandbox fleet isn't concurrent *writers*
  to the same bytes — it's N sandboxes wanting **read access** to the same base content
  (a cloned repo, a base image's files, shared reference data) while only a small, isolated
  slice is genuinely mutable per-leaf (`/workspace/leaves/<sid>`, already isolated today).
- If the immutable/shared portion (e.g., the converged base repo) lives in a **read-only
  fileset**, cross-pod read contention becomes a non-issue by construction — there's no lock
  to take, because there's nothing to write. Only the per-leaf mutable worktree needs RW,
  and that's already namespaced per session.
- This reframes Phase 2's flock-based mutual exclusion as possibly the wrong tool for the
  job — not "make the lock safer," but "eliminate the need for cross-pod write locking on
  the shared portion entirely."
- Not started. Needs: (a) confirm GPFS RO-fileset semantics/CSI support for this cluster,
  (b) a converge.ts change to split "shared read-only base" from "per-leaf mutable worktree"
  onto separate mounts/filesets.

---

## Slide 9 — Phase 5: AFM-to-S3 for agent results

- GPFS **AFM (Active File Management)** can tier/replicate to an S3-compatible object
  store — use this to durably ship agent run results (BugStone reports, SWE-agent patches,
  audit logs) out of the cluster's block/file storage and into S3 for long-term retention,
  cross-cluster access, or downstream analytics.
- Not started. Open questions: which S3 endpoint (IBM Cloud Object Storage vs. other),
  AFM mode (independent-writer vs. read-only cache), what exactly gets tiered (raw results
  dir vs. a curated subset).

---

## Slide 10 — Open question: git repos for BugStone/SWE-bench on GPFS

- Today, BugStone/SWE-agent workloads get their target repo onto sandbox pods via a
  dedicated `gitd` distribution service (a small git-daemon the harness pushes to, sandboxes
  clone from) — explicitly chosen in P2 to avoid needing a shared filesystem at all.
- Open question for this effort: once GPFS is available and proven safe for shared state,
  does `gitd` still pull its weight, or could target repos be **staged directly on GPFS**
  (e.g., in the read-only fileset from Phase 4) and skip a network git clone per sandbox
  entirely?
- Not started — deliberately deferred until Phase 4's read-only fileset shape is settled,
  since the answer likely depends on it.

---

## Slide 11 — Phase 6: demo (TBD)

- Goal: a concrete, visual demonstration of GPFS's value as the storage layer — not just
  "it works," but "here's what it buys you that per-pod storage couldn't."
  Candidate angles (not yet chosen):
  - Side-by-side: an agent's shared workspace surviving a sandbox pod recycle/reschedule
    (state persists because it's not pod-local).
  - Live shared-PVC file view during a real BugStone Act 2 run — watch multiple sandboxes
    touch the same mount concurrently, with contention visibly handled (or not).
  - A read-only-fileset variant vs. a shared-RWX-with-locking variant, run side by side,
    showing the contention difference directly.
- See `demo/gpfs-scale/` in this repo for the harness being built to support this (watch
  scripts for sandboxes/harness pods/leaf-workers, shared-storage visualization).

---

## Slide 12 — Architecture diagram

See [`docs/diagrams/2026-07-17-gpfs-scale-environment.md`](../diagrams/2026-07-17-gpfs-scale-environment.md)
(Mermaid). Covers: IBM Cloud hyperconverged compute+storage nodes, Storage Scale/GPFS +
CSI driver (CNSA), Kubernetes (K8s or OCP), serverless-harness (Knative harness, Redis,
gitd, sandbox pool), and a local llm-d-served model — no external model API dependency.

---

## Slide 13 — Status summary / next steps

- ✅ Phase 1 (multi-sandbox, per-pod PVC) — done, upstream-mergeable, already largely shipped.
- 🚧 Phase 2 (shared RWX PVC) — mechanism proven (shared mount confirmed); correctness
  under real concurrent load still being validated (Act 2 issue, Slide 7).
- ⬜ Phases 4–7 — not started; each has a concrete, scoped starting question above.
- **Immediate next step:** resolve the Act 2 leaf-worker stuck-message bug (confirm
  storage-independent root cause), then re-run Act 2 clean before calling Phase 2/3 signed off.

---

*Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>*
