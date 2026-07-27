# Dynamic workload pools with Context Service

This follow-up preserves the original static GPFS demo in `demo/gpfs-scale` and
changes one thing: a workload asks serverless-harness (SH) to allocate its own
sandbox pool at run time.

## Workload flow

```text
POST /workloads
  SH -> Context Service -> 3 sandboxes + one shared GPFS workspace

POST /runs { workloadId, ... }
  SH -> workloadId -> pool selector -> the workload's sandboxes

DELETE /workloads/{workloadId}
  SH -> Context Service -> delete sandboxes + workspace
```

The BugStone adapter knows only the SH `workloadId`. It does not call Context
Service and does not receive a Kubernetes selector.

## Run the follow-up demo

The static demo must already be deployed and Context Service must be running in
the `serverless-harness` namespace.

```sh
./demo/context-service/run-bugstone.sh act1
./demo/context-service/run-bugstone.sh act2
```

The wrapper creates and waits for a workload, runs the existing BugStone demo,
and releases the workload on exit. To inspect the pool afterward:

```sh
KEEP_POOL=1 ./demo/context-service/run-bugstone.sh act1
```

`KEEP_POOL=1` currently retains both the workspace and sandboxes. A later
Context Service slice can separate stopping compute from retaining storage.

## API example

```json
POST /workloads
{
  "name": "bugstone-demo",
  "sandboxes": 3,
  "workspace": {
    "shared": true,
    "size": "5Gi",
    "storageClass": "ibm-scale-csi"
  }
}
```

SH returns a `workloadId`. Every leaf includes only that ID:

```json
POST /runs
{
  "workloadId": "bugstone-demo",
  "sessionId": "bugstone-demo/leaf-1",
  "item": { "item_id": "leaf-1", "file": "app.py", "pattern": "..." }
}
```

Runs without `workloadId` continue using the statically configured sandbox pool,
so the original GPFS demo remains a valid fallback.
