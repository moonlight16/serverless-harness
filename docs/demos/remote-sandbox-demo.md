# Demo: "The sandbox that isn't in your cluster"

A ~10-minute walkthrough of **SandboxTransport**: the harness dispatches a leaf's tool calls to a
sandbox running as a plain `docker run` **on your laptop** — outside the cluster, with **zero
inbound rules**, holding no cluster credential.

The task — grep a file for a pattern — is just a vehicle. The real show is *which machine's
filesystem answers*. You will send the same request twice and get opposite verdicts, then plant a
secret in a container by hand and watch the cluster read it back.

```
laptop
|- kind cluster:  Knative + Redis + harness (ksvc) + sandbox-relay
|                     ^                                    ^
|                     | harness -> relay                   | worker -> relay
|                     | sandbox-relay.default.svc:8443     | host.docker.internal:8443
\- docker run:    remote-worker  --------- dials out ------/
```

Neither address is inbound to the laptop.

| Act | What a normal remote sandbox needs | What SandboxTransport needs |
|-----|-----------------------------------|-----------------------------|
| **1 — Inverted connectivity** | An inbound port, a firewall rule, a public address the cluster can reach | **Nothing.** The worker dials *out* and parks a stream. `docker run` with no `-p` at all |
| **2 — Provable placement** | Trust that the config routed where you think | A **fingerprint** and a **structural guard** — a green run on the wrong backend is made impossible |
| **3 — Zero standing authority** | A kubeconfig, or an agent with cluster reach | One bearer token. No LLM key, no kubeconfig, no orchestration |

Prefer it non-interactive? `make demo-remote-sandbox` does all of this in one command and asserts
every step. This document is the version you drive by hand so you can explain each move.

---

## Act 0: Install

You need a **warm** harness cluster — this demo adds the remote path to it, it does not build it.
If you do not have one:

```bash
git clone --recurse-submodules https://github.com/rossoctl/serverless-harness.git
cd serverless-harness

export ANTHROPIC_API_KEY=sk-...    # ...or a gateway: ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN

./deploy/knative/setup-kind.sh
```

> The model must be reachable **from the cluster** — the leaf's verdict is a real model call.
> See [`../../deploy/knative/README-kind.md`](../../deploy/knative/README-kind.md) for setup
> options and [`../../deploy/knative/README-worker.md`](../../deploy/knative/README-worker.md)
> for the worker/relay reference.

Set the convenience vars used throughout:

```bash
export NS=default KSVC=serverless-harness
export HOSTHDR='Host: serverless-harness.default.example.com'
export BASE=http://localhost:8080
mkdir -p /tmp/demo-remote
```

### Check nothing else holds :8080

A leftover port-forward pointing at a **different** cluster will silently take your dispatches,
while your `kubectl` assertions run against this one:

```bash
pgrep -fl 'kubectl port-forward'   # expect empty
```

### Open two terminals

**T1 — the star. Watch the presence record appear and vanish here:**

```bash
while sleep 2; do kubectl exec deploy/redis -n default -- redis-cli HGETALL sh:sandbox:records; echo ---; done
```

**T2 — the driver. Port-forward Kourier:**

```bash
kubectl port-forward -n kourier-system svc/kourier 8080:80
```

In a second T2 shell (leave the port-forward running), confirm the harness answers:

```bash
curl -s -o /dev/null -w 'harness HTTP %{http_code}\n' --max-time 5 -H "$HOSTHDR" $BASE/
# => harness HTTP 404
```

> **`404` is success.** This is a transport check, not a health check: any response proves the
> tunnel and Host header reach the harness. Skipping it is a trap — an empty `/runs` reply later
> is indistinguishable at the verdict layer from an unreachable *model*, and the two have
> completely different fixes.

### Build the worker image

```bash
docker build --load -f remote-worker/Dockerfile -t dev.local/remote-worker:demo .
```

> **No local Go toolchain** — the Dockerfile builds the binary in a `golang:1.25-alpine` builder
> stage. And this image is **never** `kind load`ed: it runs on the host, so its architecture need
> not match the kind node. That caveat only ever applied to the in-cluster worker pod.

---

# Act 1: A sandbox with no inbound route

**The claim a normal remote sandbox can't make:** *nothing can reach me, and I am still serving
your cluster's tool calls.*

### 1a. Bring up the relay

```bash
kubectl apply -f deploy/knative/relay-deployment.yaml
kubectl -n $NS rollout status deploy/sandbox-relay --timeout=90s
```

> The relay is the only thing the worker will dial. It is **inert** until both a worker attaches
> *and* the harness is switched to the remote path — so nothing is routed anywhere yet.

### 1b. Generate the registration token

```bash
TOKEN=$(openssl rand -hex 16); echo "TOKEN=$TOKEN"
kubectl set env deploy/sandbox-relay -n $NS "SH_RELAY_TOKEN=$TOKEN"
kubectl -n $NS rollout status deploy/sandbox-relay --timeout=90s
```

> Relay auth is **fail-closed**: a token mismatch rejects the Attach before the stream is ever
> parked. We mint a fresh token per run rather than using `relay-deployment.yaml`'s `dev-token`,
> because that value is a repo constant and therefore public. Patch *before* waiting on the
> rollout, so the pod that becomes Ready is already the one holding this token.

### 1c. Open the tunnel — and prove the relay is really serving

```bash
kubectl port-forward -n $NS svc/sandbox-relay 8443:8443 >/tmp/demo-remote/relay-pf.log 2>&1 &
sleep 5
(exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null && echo "connect OK" || echo "connect FAILED"
sleep 1
grep -qE 'error forwarding|connection refused|lost connection' /tmp/demo-remote/relay-pf.log \
  && echo "RELAY DEAD" || echo "relay is serving"
```

> **A bare TCP connect is not enough.** `kubectl port-forward` accepts your local connection
> first and only *then* tries the pod, so a dead relay still gives you a successful connect.
> Reading the forward log is what separates "the relay is dead" from "a container can't route
> here" — two failures with completely different fixes. The relay also needs ~4s after `Running`
> to bind, because `node --import tsx` compiles its TypeScript at startup; probing immediately is
> a race that looks exactly like breakage.

### 1d. Register the sandbox — `docker run`, no ports

```bash
docker run -d --name sh-demo-remote-worker \
  -e SANDBOX_ID=sbx-laptop-demo \
  -e RELAY_ADDR=host.docker.internal:8443 \
  -e SANDBOX_TOKEN="$TOKEN" \
  dev.local/remote-worker:demo

docker port sh-demo-remote-worker      # prints NOTHING
```

> **This is the headline.** No `-p`, no `--publish`, no inbound rule, no firewall change. The
> worker dials **out** through the tunnel and parks a stream. Show what it was handed:

```bash
docker inspect sh-demo-remote-worker --format '{{range .Config.Env}}{{println .}}{{end}}'
```

> A bearer token, a sandbox id, a relay address. **No LLM key, no kubeconfig, no
> orchestration.** If this container is stolen, the attacker gets a scoped token to one relay.

### 1e. Registration *is* the live stream

**Look at T1** — the record just appeared:

```
sbx-laptop-demo
{"sandboxId":"sbx-laptop-demo","labels":{},"capabilities":["bash","base64","file"],"capacityMax":4,"transport":"grpc"}
```

> Nothing polled. Nothing heartbeated a URL. Redis holds this record **only while the Attach
> stream is open** — the registration *is* the stream. `"transport":"grpc"` is how the harness
> knows to route over the relay instead of `kubectl exec`. We come back to T1 in Act 3.

---

# Act 2: Prove which machine ran the command

**The claim a config change can't make on its own:** *the exec provably ran there, not here.*

### 2a. Establish the discriminator first

```bash
kubectl exec sandbox-0 -n $NS -- grep '^PRETTY_NAME' /etc/os-release
docker exec sh-demo-remote-worker grep '^PRETTY_NAME' /etc/os-release
```

```
PRETTY_NAME="Alpine Linux v3.20"                    <- in-cluster pool
PRETTY_NAME="Red Hat Enterprise Linux 9.8 (Plow)"   <- remote host container
```

> The pool is Alpine, the worker is RHEL. So a leaf grepping `/etc/os-release` for `Alpine` flips
> its verdict with the backend — and the model **names the OS it read**, so you see which
> filesystem answered instead of inferring it from a green check. Verify the fingerprint *before*
> anything relies on it; an unverified discriminator makes every later assertion meaningless.

### 2b. Run A — the in-cluster pod

```bash
BODY=$(jq -nc '{sessionId:"demo-pod-1", model:"claude-haiku-4-5",
                item:{item_id:"i1", file:"/etc/os-release", pattern:"Alpine"}}')
curl -s --max-time 120 -H "$HOSTHDR" -H 'Content-Type: application/json' \
  -d "$BODY" $BASE/runs | jq '{status, verdict:.verdict.verdict, reason:.verdict.reason}'
```

```
verdict: "FLAGGED"
reason:  "...confirming the OS is Alpine Linux."
```

> Baseline. This ran on an in-cluster pod via `kubectl exec`. Nothing remote yet — the relay and
> worker are up but the harness has not been told to use them.

### 2c. Flip to the remote path — and make a pod win *impossible*

Snapshot the env first. **Look at what has to survive the flip:**

```bash
kubectl get ksvc $KSVC -n $NS -o json \
  | jq -c '.spec.template.spec.containers[0].env' > /tmp/demo-remote/env-snapshot.json
jq -r '.[] | "\(.name)  \(if .valueFrom then "<secretKeyRef>" else "="+(.value|tostring) end)"' \
  /tmp/demo-remote/env-snapshot.json
```

```
ANTHROPIC_API_KEY     <secretKeyRef>
ANTHROPIC_BASE_URL    <secretKeyRef>
ANTHROPIC_AUTH_TOKEN  <secretKeyRef>
```

Now upsert the three remote-path vars **by name**, preserving everything else:

```bash
NEWENV=$(jq -c '
  map(select(.name | IN("SH_REMOTE_SANDBOX","SH_RELAY_ADDR","KAGENTI_SANDBOX_POOL_SELECTOR") | not))
  + [{name:"SH_REMOTE_SANDBOX",value:"1"},
     {name:"SH_RELAY_ADDR",value:"sandbox-relay.default.svc:8443"},
     {name:"KAGENTI_SANDBOX_POOL_SELECTOR",value:"sh.kagenti.io/sandbox-pool=demo-remote-only"}]
' /tmp/demo-remote/env-snapshot.json)

kubectl patch ksvc $KSVC -n $NS --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":$NEWENV}]"
```

**The structural guard — the most important line in the demo:**

```bash
kubectl get pods -n $NS -l sh.kagenti.io/sandbox-pool=demo-remote-only \
  --field-selector=status.phase=Running --no-headers | grep -c .
# => 0
```

> **Say this carefully.** `SH_REMOTE_SANDBOX=1` *alone does not route to the worker.*
> `select-sandbox.ts` builds `candidates = [...pods, ...grpcRecs]` and leases least-loaded-first,
> so an idle in-cluster pod can still win the lease — and you would get a green demo that proved
> nothing. Pointing the selector at a label **no pod carries** means a pod cannot win a lease it
> is not a candidate for. Structural, not merely detected.

Wait for the new revision — a `spec.template` change mints one:

```bash
for i in $(seq 1 40); do
  C=$(kubectl get ksvc $KSVC -n $NS -o jsonpath='{.status.latestCreatedRevisionName}')
  R=$(kubectl get ksvc $KSVC -n $NS -o jsonpath='{.status.latestReadyRevisionName}')
  [ -n "$C" ] && [ "$C" = "$R" ] && { echo "ready: $R"; break; }; sleep 3
done
```

### 2d. Why that wasn't just `kubectl set env`

Worth explaining if anyone asks — the patch above is an **upsert-by-name** computed client-side,
then written back in one atomic operation. Two halves:

**The jq half — delete, then append:**

```
map(select(.name | IN("A","B","C") | not))   # keep everything NOT named A, B, or C
+ [ {A}, {B}, {C} ]                          # append the three you want
```

`IN(...)` is jq's set-membership test and `| not` inverts it, so the `map(select(...))` **drops**
any existing entry with one of those names and the `+` appends fresh ones. The delete step is what
makes it an upsert rather than a blind append: `KAGENTI_SANDBOX_POOL_SELECTOR` **already exists**
with `…pool=default`. Watch it leave the middle of the array and return at the end with the new
value — append without the filter and you get two entries of the same name, which is invalid:

```
BEFORE (8)                          AFTER (10)
0: HOME                             0: HOME
1: REDIS_URL                        1: REDIS_URL
2: SH_MODEL                         2: SH_MODEL
3: KAGENTI_SANDBOX_POOL_SELECTOR    3: LEAF_RESULT_TTL_SECONDS
4: LEAF_RESULT_TTL_SECONDS          4: ANTHROPIC_API_KEY      <secretKeyRef>
5: ANTHROPIC_API_KEY      <ref>     5: ANTHROPIC_BASE_URL     <secretKeyRef>
6: ANTHROPIC_BASE_URL     <ref>     6: ANTHROPIC_AUTH_TOKEN   <secretKeyRef>
7: ANTHROPIC_AUTH_TOKEN   <ref>     7: SH_REMOTE_SANDBOX                <- new
                                    8: SH_RELAY_ADDR                    <- new
                                    9: KAGENTI_SANDBOX_POOL_SELECTOR    <- re-added, new value
```

**The property that matters:** untouched entries are passed through as **whole objects**, never
reconstructed — which is what preserves those three `secretKeyRef`s. `kubectl set env` does not
work on a Knative `Service` at all (*"no kind Service is registered"*), and anything that rebuilds
the array from name/value pairs flattens `valueFrom` to an empty string. The model call then fails
looking exactly like an unreachable endpoint. Order shifts, which is harmless: Kubernetes only
cares about env ordering for `$(VAR)` interpolation, which this env does not use.

**The kubectl half — replace the whole array.** JSON Patch has no "upsert by name": array ops
address elements by *index*, and indices shift as you add and remove. Computing the final array in
jq and replacing `/spec/template/spec/containers/0/env` once sidesteps that arithmetic and lands
atomically. `containers/0` is the first (user) container in the revision template.

**And what the three values do:**

| Var | Effect |
|-----|--------|
| `SH_REMOTE_SANDBOX=1` | enables the remote-sandbox code path at all |
| `SH_RELAY_ADDR=sandbox-relay.default.svc:8443` | where the *harness* dials the relay — in-cluster DNS, the other end of the worker's outbound tunnel |
| `KAGENTI_SANDBOX_POOL_SELECTOR=…pool=demo-remote-only` | a label no pod carries, so the pod candidate set is empty |

The third is the load-bearing one for the demo's honesty. The first two alone would leave idle
Alpine pods in the candidate set, and least-loaded-first could hand the exec to one.

### 2e. Run B — the same request, both directions

```bash
for PAT in Alpine "Red Hat"; do
  BODY=$(jq -nc --arg p "$PAT" '{sessionId:("demo-remote-"+($p|gsub(" ";"-"))),
    model:"claude-haiku-4-5", item:{item_id:"i1", file:"/etc/os-release", pattern:$p}}')
  echo "--- $PAT ---"
  curl -s --max-time 120 -H "$HOSTHDR" -H 'Content-Type: application/json' \
    -d "$BODY" $BASE/runs | jq -r '"verdict=\(.verdict.verdict)  \(.verdict.reason)"'
done
```

```
--- Alpine ---   verdict=CLEAR    "...the system is running Red Hat Enterprise Linux 9.8."
--- Red Hat ---  verdict=FLAGGED  "...indicating this system runs Red Hat Enterprise Linux 9.8."
```

> Same request as 2b, **opposite verdict** — and the model names the OS it actually read. Both
> directions are asserted on purpose: an exec that landed on a pod fails one check or the other,
> never neither.

---

# Act 3: The closer — plant a secret, watch the cluster read it back

**The claim that ends the argument:** *you created this evidence thirty seconds ago, on this
laptop, and the cluster just read it.*

### 3a. Write a marker only your laptop has

```bash
MARK="tuscan-lentils-$RANDOM"; echo "$MARK"
docker exec sh-demo-remote-worker sh -c "echo 'secret marker: $MARK' > /tmp/proof.txt"

kubectl exec sandbox-0 -n $NS -- cat /tmp/proof.txt
# => cat: /tmp/proof.txt: No such file or directory
```

> The file exists **only** in the container on your laptop. The in-cluster pool has never seen it.

### 3b. Ask the cluster for it

```bash
BODY=$(jq -nc --arg p "$MARK" '{sessionId:"demo-proof-1", model:"claude-haiku-4-5",
        item:{item_id:"i1", file:"/tmp/proof.txt", pattern:$p}}')
curl -s --max-time 120 -H "$HOSTHDR" -H 'Content-Type: application/json' \
  -d "$BODY" $BASE/runs | jq -r '"verdict=\(.verdict.verdict)\n\(.verdict.reason)"'
```

```
verdict=FLAGGED
The pattern tuscan-lentils-29765 is present in the file /tmp/proof.txt as a secret marker.
```

> There is no `kubectl exec` anywhere in that path, no inbound route to this machine, and the
> worker holds no cluster credential — only a token it used to dial *out*. A verdict on
> `/etc/os-release` can be argued with; a random string you typed yourself cannot.

### 3c. Presence vanishes with the stream

```bash
docker stop sh-demo-remote-worker
```

**Watch T1.** The record clears on its own:

> Nothing deleted it. The Attach stream closed and the record went with it. That is what
> "registration *is* the live stream" means — and why the harness never routes to a sandbox that
> has quietly gone away.

---

# What just happened

You drove a sandbox that:

1. **Had no inbound route** — `docker run` with no `-p`, no firewall rule, reachable by nothing
   (Act 1d).
2. **Registered by existing** — its presence record *was* its open stream, and vanished with it
   (Act 1e, 3c).
3. **Provably ran the exec** — same request, opposite verdicts, with the model naming the OS it
   read, and a pool selector that made a pod win structurally impossible (Act 2).
4. **Held no standing authority** — one scoped bearer token; no LLM key, no kubeconfig (Act 1d).
5. **Read a secret you planted by hand**, which the cluster had no other way to see (Act 3b).

That is the SandboxTransport headline: the sandbox is a **pool peer**, not a replacement — the
same contract as an in-cluster pod, on a machine the cluster cannot reach.

To replay all of it non-interactively with every step asserted:

```bash
make demo-remote-sandbox DEMO_ARGS=--reuse-cluster
```

---

# Cleanup

**Restore the harness env first — this one is non-negotiable.** A harness left pointed at a
selector matching nothing breaks every later run on the cluster:

```bash
SNAP=$(cat /tmp/demo-remote/env-snapshot.json)
kubectl patch ksvc $KSVC -n $NS --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":$SNAP}]"
```

Then the rest:

```bash
docker rm -f sh-demo-remote-worker
kubectl delete -f deploy/knative/relay-deployment.yaml --ignore-not-found
pkill -f 'kubectl port-forward -n default svc/sandbox-relay'
pkill -f 'kubectl port-forward -n kourier-system svc/kourier'
```

Or let the script do all of it, including the built image:

```bash
make demo-remote-sandbox-teardown   # asks before deleting the cluster; DEMO_ARGS=--yes skips the prompt
```

---

# Notes and limits

- **`docker logs sh-demo-remote-worker` does not show individual execs.** It logs the attach and
  then only anomalies — dedup, req-id reuse, dropped terminal frames. Do not promise a live exec
  log; Act 3 is the stronger proof anyway.
- **On native Linux Docker** the relay tunnel may need `--address 0.0.0.0` plus
  `--add-host=host.docker.internal:host-gateway` on the worker, because `host.docker.internal`
  resolves to the bridge IP rather than host loopback. That makes the relay port briefly
  LAN-visible — which is exactly why Act 1b mints a fresh token instead of using the repo's public
  `dev-token`. macOS and Docker Desktop take the clean loopback path. `demo-remote-worker.sh`
  probes for this and escalates automatically, with a warning.
- **Live streaming, abort mid-stream, dual-ended timeout and reconnect→dedup** are implemented and
  unit-tested but not shown here — tracked in
  [#198](https://github.com/rossoctl/serverless-harness/issues/198). The honest line: *the
  transport does it, this demo doesn't show it yet.*

Reference: [`../../deploy/knative/README-worker.md`](../../deploy/knative/README-worker.md)
§"Laptop demo" and [`../../deploy/knative/demo-remote-worker.sh`](../../deploy/knative/demo-remote-worker.sh).
