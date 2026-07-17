# GPFS/Storage Scale shared-agent-context demo

Demo harness for the "shared agent context via IBM Storage Scale" effort
(see [`docs/presentations/2026-07-17-gpfs-scale-shared-agent-context.md`](../../docs/presentations/2026-07-17-gpfs-scale-shared-agent-context.md)).
Local/fork-only — targets the live `agentic-cloud` cluster, not Kind or CI.

Unlike `deploy/knative/e*.sh` (which spin up/tear down against an ephemeral Kind
cluster), everything here assumes `agentic-cloud` is **already deployed and running**
and just drives/observes it.

## Prerequisites

- `kubectl config get-contexts` includes `agentic-cloud`, and it's reachable
  (`kubectl --context agentic-cloud get ns serverless-harness`).
- BugStone checked out at `~/ResilioSync/github.ibm.com/dettori/BugStoneSkills`
  (adjust `BUGSTONE_DIR` in `run-bugstone.sh` if yours lives elsewhere), with
  `.jacohn/serverless-harness/agentic-cloud.env` present (see BugStone's own
  `RUNBOOK.md` for how that env file is produced).
- The sandbox pool is already on the config you want to demo — see
  `../../deploy/knative/agentic-cloud/` (per-sandbox RWO, Phase 1 baseline) vs.
  `sandbox-pool.yaml` + `sandbox-workspace-pvc.yaml` on
  `experiment/shared-rwx-sandbox` (shared RWX, Phase 2+). This demo doesn't
  apply/switch pool config itself — that's a deliberate, reviewed step (see the
  branch's own commit).

## Layout

```
demo/gpfs-scale/
├── README.md               this file
├── run-bugstone.sh          drive Act 1 (sync) or Act 2 (async) against agentic-cloud
└── watch/
    ├── sandboxes.sh         live view: sandbox pods, node placement, PVC binding
    ├── harness-pods.sh      live view: harness ksvc pods + leaf-worker scale-out
    └── shared-storage.sh    live view: shared-PVC contents + per-pod visibility proof
```

Run each `watch/*.sh` in its own terminal pane alongside `run-bugstone.sh` — they're
independent, read-only, `watch`-style loops (Ctrl-C to stop), meant to be visible
side-by-side during a live demo.

## Quick start

```bash
# Terminal 1 — drive the workload
./run-bugstone.sh act1        # sync, one leaf at a time
./run-bugstone.sh act2        # async, KEDA-scaled parallel leaves

# Terminal 2
./watch/sandboxes.sh

# Terminal 3
./watch/harness-pods.sh

# Terminal 4 — only meaningful under the shared-RWX config (Phase 2+)
./watch/shared-storage.sh
```

## Contention + read-only fileset (Phase 3/4)

`run-bugstone.sh act2` is the concurrency stress test: KEDA scales multiple
`leaf-worker` pods in parallel, all executing into the sandbox pool concurrently.
Under the shared-RWX config, this is exactly the scenario that exercises
`harness/src/converge.ts`'s cross-pod `flock` on `/workspace/.sh-fetch.lock` —
watch `shared-storage.sh` during an Act 2 run to see it in action (or see it jam).

The Phase 4 idea (GPFS read-only fileset for the shared/immutable base, leaving
only the per-leaf worktree mutable) doesn't have tooling here yet — not started,
see the slide deck Slide 8. Once that split exists, this demo folder should grow
a variant of `shared-storage.sh` (or a flag) that shows the RO-fileset config
alongside the RWX+locking config, to make the contention difference visible.

---

*Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>*
