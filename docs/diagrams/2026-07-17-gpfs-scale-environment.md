# Environment diagram — GPFS/Storage Scale + serverless-harness

Supports the [GPFS/Scale shared-agent-context slide deck](../presentations/2026-07-17-gpfs-scale-shared-agent-context.md)
(Slide 12). Local/fork-only while in draft.

## Environment overview

```mermaid
flowchart TB
    subgraph IBMCLOUD["IBM Cloud — hyperconverged bare-metal/VSI nodes"]
        direction TB

        subgraph COMPUTE["Compute + storage, converged per node"]
            direction LR
            N1["agentic-node-1<br/>compute + Scale/GPFS"]
            N2["agentic-node-2<br/>compute + Scale/GPFS"]
            N3["agentic-node-3<br/>compute + Scale/GPFS"]
        end

        subgraph STORAGE["IBM Storage Scale (GPFS) cluster"]
            direction TB
            GPFS["Clustered POSIX filesystem<br/>spans N1/N2/N3"]
            CSI["CSI driver<br/>(ibm-scale-csi / CNSA)"]
            AFM["AFM gateway<br/>(Phase 5, not started)"]
            GPFS --- CSI
            GPFS --- AFM
        end

        subgraph K8S["Kubernetes (K8s or OCP)"]
            direction TB

            subgraph HARNESS["serverless-harness (Knative)"]
                KSVC["harness ksvc<br/>(runTurn, scale-to-zero)"]
                REDIS["Redis<br/>session + work-queue"]
                GITD["gitd<br/>git distribution service"]
            end

            subgraph POOL["Sandbox pool (agent-sandbox CRDs)"]
                SB0["sandbox-0"]
                SB1["sandbox-1"]
                SB2["sandbox-2"]
            end

            subgraph WORKERS["leaf-worker (KEDA ScaledJob)"]
                LW["leaf-worker pods<br/>0 -> N -> Completed"]
            end
        end

        subgraph LLM["Local model serving"]
            LLMD["llm-d<br/>self-hosted model endpoint"]
        end
    end

    CLIENT["BugStone / SWE-agent<br/>driver (external, e.g. laptop)"]

    CLIENT -->|HTTP: enqueue run| KSVC
    KSVC <--> REDIS
    REDIS -->|leaf-queue stream| LW
    LW -->|kubectl exec| SB0
    LW -->|kubectl exec| SB1
    LW -->|kubectl exec| SB2
    KSVC -->|model calls| LLMD
    LW -->|model calls| LLMD
    CLIENT -->|stage target repo| GITD
    GITD -->|clone per-sandbox<br/>Phase 1-3, RWO| SB0
    GITD -->|clone per-sandbox<br/>Phase 1-3, RWO| SB1
    GITD -->|clone per-sandbox<br/>Phase 1-3, RWO| SB2

    CSI -.->|PVC: per-sandbox RWO<br/>Phase 1| SB0
    CSI -.->|PVC: per-sandbox RWO<br/>Phase 1| SB1
    CSI -.->|PVC: per-sandbox RWO<br/>Phase 1| SB2
    CSI ==>|PVC: shared RWX<br/>Phase 2+| SB0
    CSI ==>|PVC: shared RWX<br/>Phase 2+| SB1
    CSI ==>|PVC: shared RWX<br/>Phase 2+| SB2
    AFM -.->|tier results to S3<br/>Phase 5, not started| S3["S3-compatible<br/>object storage"]

    classDef notstarted stroke-dasharray: 5 5
    class AFM,S3 notstarted
```

## Notes

- **Hyperconverged**: compute and Storage Scale are colocated on the same 3 nodes
  (`agentic-node-1/2/3`) — no separate storage tier/appliance.
- **CSI driver**: labeled `ibm-scale-csi` in this cluster's `StorageClass`
  (provisioner `spectrumscale.csi.ibm.com`); functionally the same integration path as
  CNSA (Container Native Storage Access) on OCP — diagram is agnostic to which.
- **Solid arrows** = built/proven. **Dashed** = Phase 1 baseline being superseded, or
  not-yet-started (AFM/S3, Phase 5).
- **Double arrows (`==>`)** = the Phase 2+ shared-RWX path this effort is validating.
- **llm-d** is local/self-hosted — no external model API in the loop, relevant for both
  cost and for keeping the whole demo environment self-contained on this cluster.
- K8s vs. OCP: today's `agentic-cloud` cluster is plain k3s; the diagram uses "K8s or OCP"
  because the harness supports both install paths (`setup-k8s.sh` / `setup-ocp.sh`) and
  this environment isn't tied to one.

---

*Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>*
