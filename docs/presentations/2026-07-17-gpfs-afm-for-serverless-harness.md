# GPFS + AFM for serverless-harness: an educational walkthrough

Slide-deck planning doc (Markdown outline → PowerPoint). Team-facing, educational — the
goal is to get the serverless-harness team oriented on what IBM Storage Scale (GPFS) +
AFM concretely offer this project, not to lock in a design. Local/fork-only while in draft.

Companion to [`2026-07-17-gpfs-scale-shared-agent-context.md`](2026-07-17-gpfs-scale-shared-agent-context.md)
(the phased-plan deck) — that one tracks *our* project's phases; this one teaches the
*mechanism* two of those phases (5 and the new DR idea below) depend on, for an audience
that hasn't necessarily seen AFM before.

Status: DRAFT.

---

## Slide 1 — Title

**GPFS + AFM for serverless-harness**
What Storage Scale's Active File Management can do for agent results and disaster
recovery — an educational walkthrough for the team.

---

## Slide 2 — Why this deck

- The GPFS/Scale effort deck (companion doc) covers *our* phased plan for shared agent
  context. This deck zooms into one piece of that plan — **AFM** — and asks a broader
  question: now that serverless-harness runs on a GPFS-backed cluster, what does AFM
  actually make possible for us?
- Two concrete, motivating use cases:
  1. **Ship agent results to S3** — BugStone reports, SWE-agent patches, audit logs,
     durably out of the cluster.
  2. **Disaster recovery** — if the cluster or the workspace PVC goes corrupt, can we
     restore serverless-harness state from S3?
- Not a design doc yet — a shared-understanding pass so the team can reason about which
  AFM mode/pattern fits which problem, before we commit to one.

---

## Slide 3 — AFM in one slide

- **Active File Management (AFM)** is a GPFS fileset-level feature that asynchronously
  connects a fileset to a remote target — another GPFS cluster, or (relevant here) an
  **S3-compatible object store** ("AFM to Cloud Object Storage" / AFM2COS).
- A **gateway node** (a member of the cluster that *owns* the fileset) runs the AFM
  **queue**: it queues file operations, pushes/pulls them to the target asynchronously,
  and can recover the queue after a gateway failure.
- Four fileset modes, same mental model whether the target is another GPFS cluster or S3:

  | Mode | Direction | Use case |
  |---|---|---|
  | **SW** (single-writer) | local → target, one-way push | Archive / backup / tiering |
  | **IW** (independent-writer) | local ↔ target, multiple independent writers | Distributed ingest, multi-site fan-in |
  | **RO** (read-only) | target → local, pull/cache only | Read-through cache of remote content |
  | **LU** (local-update) | target → local, plus local edits allowed | Read-mostly with occasional local overrides |

- **Key property for both our use cases:** AFM is *asynchronous* — writes land locally
  first (fast, no S3 round-trip in the write path), then get queued out to the target in
  the background. This matters for agent workloads, which write fast and often.

---

## Slide 4 — One important constraint: where the gateway can live

- The AFM gateway must be a **member node of the cluster that owns the fileset** — it
  cannot be a node that only remote-mounts the filesystem.
- serverless-harness's k8s cluster (CNSA-style: GPFS core pods as a DaemonSet, remote-
  mounting a filesystem owned by a separate storage cluster) is exactly this
  remote-mount relationship — see `docs/diagrams/2026-07-17-gpfs-scale-environment.md`.
- **Implication:** the AFM relationship for either use case below must be set up on the
  **storage cluster side** (where the fileset is actually owned), not from a pod inside
  the k8s cluster. serverless-harness's role is to write into the fileset via its normal
  PVC mount — the AFM queue/gateway machinery is invisible to it and lives elsewhere.
- This is a real constraint worth surfacing early, since it shapes who sets this up
  (storage/infra team) vs. what the harness itself needs to change (nothing, for writes).

---

## Slide 5 — Use case 1: agent results to S3 (AFM2COS, SW or IW mode)

- **Goal:** durably ship BugStone/SWE-agent run results (reports, audit JSON, patches,
  logs) out of the workspace PVC and into S3, for long-term retention, cross-cluster
  access, or downstream analytics — without the harness/sandbox code talking to S3 directly.
- **Mechanism:** a GPFS fileset (or a subdirectory of one) holding results is configured
  as an **AFM to Cloud Object Storage** fileset in **SW** (if only this cluster ever
  produces results) or **IW** mode (if we want multiple write sources feeding the same
  S3 bucket, e.g. multiple clusters/environments later).
  - Writes land in the fileset immediately (agent-speed, no S3 latency).
  - AFM queues and pushes each write to the S3 bucket asynchronously, in the background.
- **What serverless-harness needs to change:** likely nothing in application code — just
  write results under the AFM-managed fileset path instead of (or in addition to) wherever
  they land today. The tiering is transparent below the filesystem layer.
- **Open questions (to work through with the team):**
  - Which S3 endpoint — IBM Cloud Object Storage vs. something else?
  - Fileset granularity: one AFM2COS fileset for all results, or per-run/per-workload?
  - Retention/lifecycle on the S3 side — do we ever need to *read back* from S3, or is
    this pure archive? (Answer shapes mode choice and whether RO/LU matters here too.)
  - How does this interact with `gitd`/BugStone's own `results/run-*` directory layout —
    tier the whole tree, or a curated subset (e.g. just `report.html` + `completion_audit.json`)?

---

## Slide 6 — Use case 2: disaster recovery — restoring cluster/PVC state from S3

- **The ask:** if the cluster or the shared workspace PVC gets corrupted, can we restore
  serverless-harness's state from what's in S3?
- **First, scope what "state" means** — this needs to be pinned down before any mechanism
  choice makes sense:
  - **Agent/session state** — Redis (session streams, work-queue). This is *not*
    filesystem state at all; AFM doesn't apply here directly. Redis has its own
    persistence story (RDB/AOF snapshots) — a separate concern from GPFS/AFM, though the
    snapshot files themselves could live on a GPFS-backed volume and ride along with
    whatever fileset-level DR we set up.
  - **Shared workspace PVC contents** — the actual filesystem data (`/workspace`,
    converged repos, per-leaf worktrees). This is squarely GPFS/AFM territory.
  - **Results already tiered to S3** (Slide 5) — already durable in S3 independent of
    cluster health; "restoring" these is just re-reading them, not a DR mechanism.
- **Two GPFS mechanisms that could apply, and they are NOT the same thing:**
  1. **AFM2COS in RO/LU mode, used as a recovery path** — if the *live* workspace fileset
     is itself an AFM2COS fileset (RO or LU) backed by S3, then losing the local cache
     (corrupted PVC, cluster rebuild) just means re-provisioning the fileset against the
     same S3 bucket and letting AFM re-populate on demand (read-through) or via a bulk
     prefetch (`mmafmctl prefetch`). This reuses the *same* AFM relationship as Slide 5,
     but requires the workspace's primary copy semantics to tolerate RO/LU (no arbitrary
     local writes that aren't itself the source of truth) — needs thought given
     `/workspace` is actively read-written by sandboxes today (SW/IW, not RO/LU).
  2. **AFM-DR (Asynchronous Disaster Recovery)** — a distinct, purpose-built GPFS→GPFS
     fileset-level DR feature (not S3-based — target is another GPFS cluster/fileset,
     with defined failover/failback procedures). This is the "real" DR answer if the
     target is meant to be another Scale cluster rather than an object store, and is
     the more mature/tested path for RPO/RTO-driven recovery. Worth knowing this exists
     even though it doesn't directly satisfy "restore from **S3**."
- **Bottom line for the team:** the user's instinct ("GPFS/AFM can do a lot here") is
  right, but "replicate to S3 and restore" cleanly maps to AFM2COS only if we're willing
  to make the workspace fileset itself RO/LU-shaped (source of truth lives in S3, local
  is a cache) — which is a bigger architectural change than just "add a backup." If we
  want SW/IW-style "local is the source of truth, S3 is a backup," restoring from S3 is a
  more manual `mmafmctl`/re-seed exercise, not an automatic failover. **This needs a
  working session, not just this slide** — flagged as the next concrete follow-up.

---

## Slide 7 — Where this fits our phased plan

- Maps onto Phase 5 (AFM-to-S3) of the [phased-plan deck](2026-07-17-gpfs-scale-shared-agent-context.md),
  plus a new DR thread that isn't in that phase list yet.
- Suggested sequencing:
  1. Start with **Slide 5's use case** (results → S3, SW/IW) — it's additive, doesn't
     change the live read/write path, and is the more standard/lower-risk AFM pattern.
  2. Treat **Slide 6's DR use case** as a design spike, not an implementation task yet —
     it needs a decision on workspace fileset semantics (can `/workspace` tolerate
     RO/LU?) before a mechanism can even be chosen.
- Depends on Phase 4 (read-only fileset for contention) conceptually — if Phase 4 already
  splits the workspace into a "shared immutable base" (candidate for RO/LU + S3 origin)
  vs. "per-leaf mutable worktree" (stays SW/IW, local-only or its own separate tiering),
  that split may be exactly what makes Slide 6's DR idea tractable. Worth solving Phase 4
  and this DR question together rather than in isolation.

---

## Slide 8 — Open questions / next steps

- [ ] Pin down what "serverless-harness state" means for DR purposes (Slide 6) — get
      agreement on scope (Redis vs. PVC vs. both) before picking a mechanism.
- [ ] Decide results-to-S3 (Slide 5) fileset granularity and S3 endpoint.
- [ ] Confirm with storage/infra who owns setting up the AFM gateway/relationship on the
      storage-cluster side (Slide 4's ownership constraint) — this isn't something the
      serverless-harness team can self-serve from the k8s side alone.
- [ ] Investigate whether the live workspace fileset could be reshaped as RO/LU (Slide 6,
      option 1) as part of the Phase 4 read-only-fileset work already planned.
- [ ] If true cross-cluster DR (not just S3 backup) becomes a hard requirement, evaluate
      AFM-DR properly (separate from everything else in this deck).

---

*Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>*
