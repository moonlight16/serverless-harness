# Agent Mosaic

Agent Mosaic is a playful producer/consumer demonstration for Serverless Harness (SH), Context
Service, and shared GPFS storage.

One producer agent reads a small creative seed and generates a shared world brief on an existing
GPFS PVC. SH then fans that immutable brief out to many consumer agents. Each consumer mounts the
same claim read-only and contributes one interpretation. A deterministic renderer combines their
responses into a self-contained animated HTML mosaic.

```text
producer agent -> read-write workspace -> world-brief.md
                                      |
                         Context Service handoff
                                      |
                  20–100 consumers <- read-only workspace
                                      |
                           animated HTML mosaic
```

## Run

The Context Service demo stack must already be deployed. Create the mosaic's dedicated GPFS
workspace once:

```sh
kubectl apply -f demo/agent-mosaic/pvc.yaml
```

This also creates a small read-only storage viewer Pod used by the dashboard after workload
sandboxes have been released. It never mounts or reads the BugStone workspace.

By default the demo uses the `agent-mosaic-workspace` claim, five sandbox pods, and twenty agent
runs. This PVC is intentionally separate from the BugStone demo workspace and persists across
producer and consumer pools.

```sh
./demo/agent-mosaic/run.sh
```

Keep the live dashboard open in another terminal before starting the run:

```sh
./demo/agent-mosaic/dashboard.sh
```

The dashboard shows the producer/read-write and consumer/read-only lifecycle, Sandbox resources,
their Pods and node placement, the durable PVC, a live view of `/workspace` on GPFS, fan-out
progress, run settings, and generated artifacts. It can remain open between runs and automatically
follows the newest output directory.

Scale it up without changing the demo:

```sh
COUNT=100 SANDBOXES=10 PARALLEL=20 ./demo/agent-mosaic/run.sh
```

`PARALLEL` may exceed the sandbox pool's immediately available capacity. The runner follows SH's
`503 Retry-After` response and safely retries those requests as leases become available.

Useful overrides:

- `CLAIM` — existing RWX PVC name (default `agent-mosaic-workspace`).
- `MODEL` — model passed to each `/runs` call.
- `COUNT` — number of consumer agent runs.
- `SANDBOXES` — size of the read-only sandbox pool.
- `PARALLEL` — maximum simultaneous HTTP requests from the driver.
- `KEEP_POOLS=1` — retain Context Service pools for inspection.

Results are written beneath `demo/agent-mosaic/output/`. Open `mosaic.html` in a browser and click
individual tiles to read the contributing agent's interpretation.

The first version intentionally keeps orchestration in the demo driver. It proves fan-out and the
read-write-to-read-only context handoff without adding mosaic-specific behavior to SH or Context
Service.

The default is Llama 3.3 70B because the smaller 8B model available in the demo cluster does not
reliably follow SH's structured `submit_verdict` tool contract.
