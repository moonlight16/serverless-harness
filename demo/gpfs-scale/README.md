# Shared workspace context with GPFS / IBM Storage Scale

Serverless-harness is a cloud-native runtime for running AI agent sessions on
Kubernetes. Agent tools execute in a pool of sandbox pods, each with a `/workspace`
for the files, data, and artifacts needed by the agent.

[BugStone](https://github.ibm.com/dettori/BugStoneSkills) is a vulnerability-detection
workflow that uses this parallel execution model. It identifies potential
vulnerabilities, then fans out leaf agents to verify them. Those agents run across the
sandbox pool but need access to the same target repository.

Normally, each sandbox has its own PVC and isolated workspace. This demo instead
mounts one **ReadWriteMany (RWX) PVC**, backed by GPFS / IBM Storage Scale, across the
entire pool. BugStone provides a concrete example: sharing the workspace reduces
duplicate repository clones while its leaf agents continue to run in parallel.

More broadly, this makes workspace context a deployment choice: **isolated per
sandbox** or **shared across the pool**. A future Context Service could manage that
choice and the lifecycle of the workspace context.

## Prerequisites

This demo was built and run against the IBM Cloud `agentic-node` cluster (the
`agentic-cloud` Kubernetes context). It assumes:

- GPFS / IBM Storage Scale is installed, with the `ibm-scale-csi` StorageClass.
- Serverless-harness is deployed in the `serverless-harness` namespace with its
  sandbox pool, Redis, `gitd`, and KEDA worker configuration.
- Every sandbox mounts the same RWX PVC at `/workspace`.
- The serverless-harness endpoint and its `x-sh-auth` gateway policy are available.
- You have access to the internal
  [BugStoneSkills](https://github.ibm.com/dettori/BugStoneSkills) repository. On its
  first run, the wrapper clones the demo branch and runs BugStone's setup.
- The llm-d model `meta-llama/Llama-3.3-70B-Instruct` is available.

The scripts in this directory retain the cluster-specific settings used for the live
demo. They are intended to replay or document that environment, and can be adapted for
another cluster.

By default, the BugStone checkout is kept in the hidden, ignored
`demo/gpfs-scale/.bugstone/` directory. Set `BUGSTONE_DIR` to reuse a checkout
elsewhere. The wrapper also applies `bugstone-external-cluster.patch`, which captures
the external-gateway support that was present as local changes during the original
demo but is not on the BugStone feature branch.

## Shared workspace configuration

The key deployment change was one shared claim:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sandbox-workspace-shared
  namespace: serverless-harness
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ibm-scale-csi
  resources:
    requests:
      storage: 5Gi
```

Each Sandbox mounted that claim at `/workspace` instead of using a per-sandbox
`volumeClaimTemplate`:

```yaml
spec:
  podTemplate:
    spec:
      volumes:
        - name: workspace
          persistentVolumeClaim:
            claimName: sandbox-workspace-shared
      containers:
        - name: sandbox
          volumeMounts:
            - name: workspace
              mountPath: /workspace
```

## Run it

Keep the live dashboard open in one terminal:

```bash
./dashboard.sh
```

Then launch a pipeline run from another terminal:

```bash
# Act 1 — synchronous leaf dispatch
./run-bugstone.sh act1

# Act 2 — KEDA-scaled parallel leaves
./run-bugstone.sh act2

# Optional: run either act with a different llm-d model
MODEL="another/model" ./run-bugstone.sh act1
```

The dashboard waits for and automatically follows the newest Act 1 or Act 2 run, so it
can remain open across multiple runs. The pipeline still streams its normal output in
the second terminal and records the same output for the dashboard. Press Ctrl-C in the
dashboard terminal when you are finished.

The Rich dashboard polls the cluster asynchronously and shows Knative harness pods and
KEDA workers scaling live. It also displays Redis queue depth, a changing tree of the
shared `/workspace`, the fixed BugStone pipeline phases, and a rolling raw log. Its
`rich` and `click` dependencies are installed into a hidden Python environment on
first use. The runner prints the full log path, result path, and
completion-audit status.

On the recorded Act 1 environment, the seven Phase B candidates drove the Knative
harness from one pod to its configured maximum of five, then back toward zero. The
dashboard retains the observed peak even after the pods scale down.
