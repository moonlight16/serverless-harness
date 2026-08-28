#!/usr/bin/env bash
# deploy/knative/relay-leaf-smoke.sh
# Gated Kind smoke proving a leaf's tool calls execute on a remote gRPC-relay worker
# (packages/sandbox-relay + remote-worker), NOT on an in-cluster kubectl-exec sandbox pod.
#
# Why this needs more than "the leaf came back done": select-sandbox.ts builds
# candidates = [...pods, ...grpcRecs] and leases least-loaded-first. With
# SH_REMOTE_SANDBOX=1 set and a worker connected, an idle in-cluster sandbox pod can
# still win the lease — a green leaf run does NOT by itself prove the remote worker
# served it. This smoke forces the pool selector to match no local pods (so only the
# worker is a candidate) and, more importantly, fingerprints the OS the exec actually
# ran on: the in-cluster sandbox pool runs Alpine (sandbox-pool.yaml), the worker image
# this script builds runs RHEL (registry.access.redhat.com/ubi9/ubi-minimal). A leaf
# grepping /etc/os-release for "Alpine" is FLAGGED on a pod / CLEAR on the worker; for
# "Red Hat" it's the reverse. Both are asserted against the remote path, so a leaf that
# quietly landed on a pod is caught either way. The discriminator itself is verified
# (not assumed) before it's relied on.
#
# Sequence: preflight -> build/accept a worker image -> deploy relay + worker -> assert
# Redis presence (transport=grpc) -> validate the Alpine/RHEL discriminator -> snapshot
# the harness env -> flip to the remote path with a non-matching pool selector -> assert
# both remote fingerprints -> restore the harness env -> control run (pod path must work
# again) -> teardown relay/worker -> assert presence is gone. Restore is trap-driven
# (EXIT) so an interrupted or failing run never leaves the cluster flipped with a
# selector matching nothing -- the worst outcome this script could produce.
#
# Prereq: setup-kind.sh done (harness + redis + sandbox pool up); go + docker + kind
#   available locally to cross-compile/build/load the worker image (or pass a
#   pre-loaded WORKER_IMAGE); llm-credentials secret populated (model reachable).
# Usage: RELAY_LIVE_SMOKE=1 bash deploy/knative/relay-leaf-smoke.sh
#        WORKER_IMAGE=dev.local/remote-worker:preloaded RELAY_LIVE_SMOKE=1 bash deploy/knative/relay-leaf-smoke.sh
#
# On a real cluster (e.g. OpenShift) the kind assumptions above do not hold; set all
# three of KSVC_URL (the harness Route; lib.sh then targets it directly), RELAY_IMAGE
# (a relay image the cluster can pull), and WORKER_IMAGE (skips the kind-load path).
# See deploy/knative/README-worker.md "Running the live gate on a real cluster".
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh   # NS, KSVC, BASE, HOST_HEADER, CURL_OPTS, CURL_HDR, ok/ko, PASS/FAIL,
                   # ensure_port_forward, wait_ksvc_ready, set_ksvc_env

[ "${RELAY_LIVE_SMOKE:-0}" = "1" ] || { echo "SKIP (set RELAY_LIVE_SMOKE=1)"; exit 0; }

CLUSTER_NAME="${CLUSTER_NAME:-sh-knative}"
MODEL="${SH_MODEL:-claude-haiku-4-5}"
WORKER_IMAGE="${WORKER_IMAGE:-}"
SANDBOX_ID="sbx-relay-smoke-$$"
WORKER_DEPLOY="sandbox-worker-relay-smoke"
RELAY_ADDR="sandbox-relay.${NS}.svc:8443"
NONEXISTENT_SELECTOR="sh.kagenti.io/sandbox-pool=relay-smoke-none-$$"

BUILD_DIR=""
HARNESS_ENV_SNAPSHOT=""
HARNESS_FLIPPED=0
BUILT_IMAGE=0

claim() { echo ""; echo "--- $1 ---"; }
abort() { echo "ABORT: $1" >&2; exit 1; }

# Exact-restore the harness env from the snapshot taken before flipping. Idempotent:
# a no-op once HARNESS_FLIPPED is cleared, so both the normal-flow call (step 9) and the
# EXIT trap can call it safely.
restore_harness_env() {
  [ "$HARNESS_FLIPPED" = 1 ] || return 0
  [ -n "$HARNESS_ENV_SNAPSHOT" ] || return 0
  echo "restoring harness env to pre-flip snapshot..."
  if kubectl patch ksvc "$KSVC" -n "$NS" --type=json \
       -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":$HARNESS_ENV_SNAPSHOT}]" \
       >/dev/null 2>&1; then
    wait_ksvc_ready
    HARNESS_FLIPPED=0
  else
    echo "WARN: restore patch failed; leaving HARNESS_FLIPPED set so the EXIT trap retries (see kubectl get ksvc/$KSVC -o json manually)" >&2
  fi
}

# Wait until the ksvc's latest-created revision is also its latest-ready revision (or
# timeout). wait_ksvc_ready swallows failures by design (`|| true`); this adds a hard
# check specifically for the flip/restore transitions, where serving the wrong revision
# would mean asserting against the wrong backend. Usage: wait_latest_ready [timeoutSec]
wait_latest_ready() {
  local timeout="${1:-150}" waited=0 created ready
  while [ "$waited" -lt "$timeout" ]; do
    created="$(kubectl get ksvc "$KSVC" -n "$NS" -o jsonpath='{.status.latestCreatedRevisionName}' 2>/dev/null || true)"
    ready="$(kubectl get ksvc "$KSVC" -n "$NS" -o jsonpath='{.status.latestReadyRevisionName}' 2>/dev/null || true)"
    if [ -n "$created" ] && [ "$created" = "$ready" ]; then
      echo "  ksvc/$KSVC latest-ready revision: $ready"
      return 0
    fi
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

# Teardown relay + worker (idempotent, tolerant of "already gone"). Called both from the
# normal flow (step 10, so the presence-removal assertion below has something to assert)
# and unconditionally from the EXIT trap as a backstop.
teardown_relay_and_worker() {
  kubectl delete deploy "$WORKER_DEPLOY" -n "$NS" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
  kubectl delete -f relay-deployment.yaml --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
}

cleanup() {
  claim "Cleanup (EXIT trap): restore harness env, remove relay + worker"
  restore_harness_env
  teardown_relay_and_worker
  [ -n "$BUILD_DIR" ] && rm -rf "$BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Relay leaf smoke (sandbox=$SANDBOX_ID, model=$MODEL) ==="

# --- Preflight: abort early with a clear message on any miss; nothing below is safe to
# attempt against a cluster that fails these. ---
claim "Preflight"
kubectl cluster-info >/dev/null 2>&1 || abort "cluster unreachable (kubectl cluster-info failed)"
kubectl get ksvc "$KSVC" -n "$NS" >/dev/null 2>&1 || abort "ksvc/$KSVC not found in namespace $NS (run setup-kind.sh, or setup-ocp.sh/setup-k8s.sh on a real cluster, first)"
kubectl get deploy redis -n "$NS" >/dev/null 2>&1 || abort "deploy/redis not found in namespace $NS (run setup-kind.sh, or setup-ocp.sh/setup-k8s.sh on a real cluster, first)"

POOL_SELECTOR="$(kubectl get ksvc "$KSVC" -n "$NS" -o json \
  | jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="KAGENTI_SANDBOX_POOL_SELECTOR") | .value' 2>/dev/null || true)"
POOL_SELECTOR="${POOL_SELECTOR:-sh.kagenti.io/sandbox-pool=default}"
POOL_POD_COUNT="$(kubectl get pods -n "$NS" -l "$POOL_SELECTOR" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ "${POOL_POD_COUNT:-0}" -ge 1 ] || abort "no Running sandbox pods match pool selector '$POOL_SELECTOR' (needed for the discriminator check and the control run)"
SBOX_POD="$(kubectl get pods -n "$NS" -l "$POOL_SELECTOR" --field-selector=status.phase=Running --no-headers 2>/dev/null | awk 'NR==1{print $1}')"
echo "preflight ok: ksvc=$KSVC redis=up pool_selector='$POOL_SELECTOR' running_pool_pods=$POOL_POD_COUNT (sample=$SBOX_POD)"

ensure_port_forward >/dev/null || true

# --- Build (or accept) the worker image. Cross-compiled to match the kind node's arch,
# packaged on a shell-bearing RHEL base (which doubles as the discriminator's non-Alpine
# side), loaded into kind so the cluster can pull it with no registry. ---
claim "Worker image"
if [ -n "$WORKER_IMAGE" ]; then
  # Do not claim kind here: on a real cluster WORKER_IMAGE is a registry reference the
  # nodes pull, not an image loaded into a kind node's store.
  echo "using externally provided WORKER_IMAGE=$WORKER_IMAGE (assumed pullable by the cluster's nodes, or preloaded into kind cluster '$CLUSTER_NAME')"
else
  NODE_ARCH="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
  [ -n "$NODE_ARCH" ] || abort "could not read kind node architecture (kubectl get nodes)"
  command -v go >/dev/null 2>&1 || abort "go toolchain not found (needed to cross-compile remote-worker; or pass WORKER_IMAGE)"
  command -v docker >/dev/null 2>&1 || abort "docker not found (needed to build the worker image; or pass WORKER_IMAGE)"
  command -v kind >/dev/null 2>&1 || abort "kind not found (needed to load the worker image; or pass WORKER_IMAGE)"

  BUILD_DIR="$(mktemp -d /tmp/relay-leaf-smoke-build.XXXXXX)"
  echo "cross-compiling remote-worker for linux/$NODE_ARCH into $BUILD_DIR"
  (cd ../../remote-worker && GOOS=linux GOARCH="$NODE_ARCH" CGO_ENABLED=0 \
    go build -trimpath -ldflags "-s -w" -o "$BUILD_DIR/remote-worker" ./cmd/worker) \
    || abort "go build of remote-worker (GOARCH=$NODE_ARCH) failed"

  # RHEL UBI9-minimal: shell-bearing (needed to exec bash/coreutils for the harness's own
  # tool calls) AND the discriminator's non-Alpine side, for free.
  cat > "$BUILD_DIR/Dockerfile" <<'DOCKERFILE'
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
RUN microdnf install -y --nodocs bash coreutils-single findutils file \
    && microdnf clean all
COPY remote-worker /usr/local/bin/remote-worker
USER 1001
ENTRYPOINT ["/usr/local/bin/remote-worker"]
DOCKERFILE

  WORKER_IMAGE="dev.local/remote-worker:relay-smoke-$$"
  docker build --load --platform "linux/$NODE_ARCH" -t "$WORKER_IMAGE" "$BUILD_DIR" >/dev/null \
    || abort "docker build of worker image ($WORKER_IMAGE) failed"
  kind load docker-image "$WORKER_IMAGE" --name "$CLUSTER_NAME" >/dev/null \
    || abort "kind load docker-image ($WORKER_IMAGE into cluster $CLUSTER_NAME) failed"
  BUILT_IMAGE=1
  echo "worker image ready: $WORKER_IMAGE (built + loaded into kind cluster '$CLUSTER_NAME')"
fi

# --- Deploy relay + worker, wait for both rollouts. ---
claim "Deploy relay + worker"
# RELAY_IMAGE overrides the manifest's kind-local image (dev.local/...:local), which
# exists only in a kind node's image store. Required on any real cluster (e.g. OpenShift),
# where the relay must be pulled from a registry the cluster can reach -- applying the
# manifest unmodified there would replace a working relay with an unpullable one and
# abort at the rollout below. Unset = kind behavior, unchanged.
if [ -n "${RELAY_IMAGE:-}" ]; then
  RELAY_RENDERED=$(sed "s#image: dev.local/serverless-harness:local#image: ${RELAY_IMAGE}#" relay-deployment.yaml)
  # Verify the substitution rather than assuming it, in both directions -- they catch
  # different regressions and neither implies the other:
  #   (a) no kind-local pin survives. Guards a manifest that grows a second image line,
  #       where the new image could be present while a stale pin still ships.
  #   (b) the new image is actually present. Guards the pin being renamed, where sed
  #       matches nothing, (a) is vacuously true, and we would deploy the renamed
  #       kind-local image -- surfacing later as a confusing ImagePullBackOff.
  printf '%s' "$RELAY_RENDERED" | grep -qF 'image: dev.local/serverless-harness:local' \
    && abort "RELAY_IMAGE=$RELAY_IMAGE set, but a kind-local 'image: dev.local/serverless-harness:local' line survived the rewrite"
  printf '%s' "$RELAY_RENDERED" | grep -qF "image: ${RELAY_IMAGE}" \
    || abort "RELAY_IMAGE=$RELAY_IMAGE set, but relay-deployment.yaml has no 'image: dev.local/serverless-harness:local' line to replace"
  printf '%s\n' "$RELAY_RENDERED" | kubectl apply -f - >/dev/null \
    || abort "kubectl apply relay-deployment.yaml (RELAY_IMAGE=$RELAY_IMAGE) failed"
else
  kubectl apply -f relay-deployment.yaml >/dev/null || abort "kubectl apply relay-deployment.yaml failed"
fi
kubectl -n "$NS" rollout status deploy/sandbox-relay --timeout=90s >/dev/null \
  || abort "sandbox-relay rollout did not become ready"

cat <<WORKERYAML | kubectl apply -f - >/dev/null || abort "kubectl apply of worker Deployment failed"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $WORKER_DEPLOY
  namespace: $NS
  labels:
    app: $WORKER_DEPLOY
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $WORKER_DEPLOY
  template:
    metadata:
      labels:
        app: $WORKER_DEPLOY
    spec:
      containers:
        - name: sandbox-worker
          image: $WORKER_IMAGE
          imagePullPolicy: IfNotPresent
          env:
            - name: SANDBOX_ID
              value: "$SANDBOX_ID"
            - name: RELAY_ADDR
              value: "$RELAY_ADDR"
            - name: SANDBOX_TOKEN
              value: dev-token
WORKERYAML
kubectl -n "$NS" rollout status deploy/"$WORKER_DEPLOY" --timeout=90s >/dev/null \
  || abort "$WORKER_DEPLOY rollout did not become ready"
echo "relay + worker ($SANDBOX_ID) up"

# --- Assert presence: the worker's live Attach stream IS the registration. Registration
# happens asynchronously after the Deployment rollout completes (the worker Deployment has
# no readinessProbe -- its readiness *is* the Attach stream reaching the relay, which is not
# something an HTTP/TCP probe could observe -- so `rollout status` returning only means the
# pod is Running, not that it has registered yet). Poll with the same bounded wait used below
# for the disconnect assertion instead of a single racy check. ---
claim "Assert: worker registered in Redis presence (sh:sandbox:records, transport=grpc)"
presence_seen=0
for _i in $(seq 1 20); do
  PRESENCE="$(kubectl exec deploy/redis -n "$NS" -- redis-cli HGETALL sh:sandbox:records 2>/dev/null || true)"
  if echo "$PRESENCE" | grep -qF "$SANDBOX_ID" && echo "$PRESENCE" | grep -q '"transport":"grpc"'; then
    presence_seen=1; break
  fi
  sleep 2
done
[ "$presence_seen" = 1 ] && ok "worker $SANDBOX_ID present in sh:sandbox:records with transport=grpc" \
  || ko "worker $SANDBOX_ID not found (or wrong transport) in sh:sandbox:records; presence dump: $(echo "$PRESENCE" | head -c 300)"

# --- Validate the discriminator BEFORE relying on it. Abort (not just ko) if it doesn't
# hold -- every assertion below would be meaningless against a broken discriminator. ---
claim "Validate discriminator: sandbox pool runs Alpine, worker runs RHEL"
POD_OS="$(kubectl exec "$SBOX_POD" -n "$NS" -- cat /etc/os-release 2>/dev/null || true)"
WORKER_POD="$(kubectl get pods -n "$NS" -l app="$WORKER_DEPLOY" --field-selector=status.phase=Running --no-headers 2>/dev/null | awk 'NR==1{print $1}')"
[ -n "$WORKER_POD" ] || abort "could not find a Running pod for deploy/$WORKER_DEPLOY to read /etc/os-release from"
WORKER_OS="$(kubectl exec "$WORKER_POD" -n "$NS" -- cat /etc/os-release 2>/dev/null || true)"
if echo "$POD_OS" | grep -qi 'Alpine' && ! echo "$POD_OS" | grep -qi 'Red Hat' \
   && echo "$WORKER_OS" | grep -qi 'Red Hat' && ! echo "$WORKER_OS" | grep -qi 'Alpine'; then
  ok "discriminator holds: sandbox pod ($SBOX_POD)=Alpine, worker ($WORKER_POD)=Red Hat"
else
  abort "discriminator invalid -- sandbox pod /etc/os-release: [$POD_OS]; worker /etc/os-release: [$WORKER_OS]. Refusing to run assertions that would be meaningless without a verified discriminator."
fi

# dispatch_pattern <sessionId> <pattern> -> echoes terminal JSON from POST /runs, grepping
# /etc/os-release for <pattern>. Mirrors leaf-smoke.sh's dispatch_item curl invocation.
dispatch_pattern() {
  local sid="$1" pat="$2" body
  body=$(jq -nc --arg s "$sid" --arg m "$MODEL" --arg p "$pat" \
    '{sessionId:$s, model:$m, item:{item_id:"i1", file:"/etc/os-release", pattern:$p}}')
  # shellcheck disable=SC2086  # CURL_OPTS is intentionally word-split
  # `|| true`: a connection-level failure (timeout, connection refused) must not exit
  # the script under set -e here -- it should instead yield an empty body so
  # assert_verdict's "model endpoint unreachable" hint is reached instead of bypassed.
  curl -s $CURL_OPTS --max-time 120 ${CURL_HDR[@]+"${CURL_HDR[@]}"} \
    -H "Content-Type: application/json" -d "$body" "$BASE/runs" || true
}

# assert_verdict <label> <response-json> <want CLEAR|FLAGGED> <hint-if-wrong>
assert_verdict() {
  local label="$1" resp="$2" want="$3" hint="$4" status verdict
  status="$(jq -r '.status // empty' <<<"$resp" 2>/dev/null || true)"
  if [ -z "$status" ]; then
    ko "$label: no verdict returned (empty/non-JSON response -- likely the model endpoint is unreachable; check the llm-credentials secret / SH_MODEL); raw: $(echo "$resp" | head -c 200)"
    return
  fi
  verdict="$(jq -r '.verdict.verdict // empty' <<<"$resp" 2>/dev/null || true)"
  if [ "$verdict" = "$want" ]; then
    ok "$label: verdict=$verdict (expected $want)"
  else
    ko "$label: verdict=$verdict, expected $want -- $hint"
  fi
}

# --- Snapshot the harness's current env exactly, for exact restore later. ---
claim "Snapshot harness env (for exact restore)"
HARNESS_ENV_SNAPSHOT="$(kubectl get ksvc "$KSVC" -n "$NS" -o json | jq -c '.spec.template.spec.containers[0].env // []')"
[ -n "$HARNESS_ENV_SNAPSHOT" ] && [ "$HARNESS_ENV_SNAPSHOT" != "null" ] || abort "failed to capture the current harness ksvc env"
echo "captured $(echo "$HARNESS_ENV_SNAPSHOT" | jq 'length') env entries"

# --- Flip to the remote path. The pool selector is pointed at a label matching NO pods,
# so the only lease candidate left is the remote worker -- select-sandbox.ts's
# least-loaded-first leasing cannot pick an in-cluster pod that isn't a candidate. ---
claim "Flip harness to the remote path (pool selector matches no pods)"
set_ksvc_env SH_REMOTE_SANDBOX=1 SH_RELAY_ADDR="$RELAY_ADDR" KAGENTI_SANDBOX_POOL_SELECTOR="$NONEXISTENT_SELECTOR"
HARNESS_FLIPPED=1
wait_latest_ready 150 || abort "harness did not reach a ready latest revision after flipping to the remote path"

# --- Remote assertions: both must be consistent with execution on the RHEL worker, not
# an Alpine pod. Failure messages name the pod-landed trap explicitly. ---
claim "Assert: remote exec (Alpine must be CLEAR, Red Hat must be FLAGGED)"
resp_alpine="$(dispatch_pattern "relay-smoke-remote-alpine-$$" "Alpine")"
assert_verdict "remote/Alpine" "$resp_alpine" "CLEAR" \
  "a FLAGGED verdict here means the exec landed on an Alpine sandbox pod, not the remote RHEL worker -- the smoke did not prove what it claims to"
resp_redhat="$(dispatch_pattern "relay-smoke-remote-redhat-$$" "Red Hat")"
assert_verdict "remote/RedHat" "$resp_redhat" "FLAGGED" \
  "a CLEAR verdict here means the exec landed on an Alpine sandbox pod, not the remote RHEL worker -- the smoke did not prove what it claims to"

# --- Assert: a worker that disappears does not wedge the leaf. With the real pool
# selector restored, pods and the worker are both candidates; deleting the worker
# removes its presence record, and the next leaf must lease a pod and complete rather
# than hang or fail. This is §10's "no mid-exec durability" gate at leaf level: the
# transport-level half (an in-flight exec surfacing an error) is covered by
# packages/k8s-sandbox/test/live-relay.test.ts.
#
# NOTE: this assertion is only meaningful together with the delete below -- with the
# worker alive, a pod also returns FLAGGED for Alpine too. It proves recovery, not
# routing; the routing proof is the Alpine/Red Hat pair asserted above while the
# worker was the only candidate. ---
claim "Assert: worker disconnect re-leases a healthy sandbox"
set_ksvc_env SH_REMOTE_SANDBOX=1 SH_RELAY_ADDR="$RELAY_ADDR" KAGENTI_SANDBOX_POOL_SELECTOR="$POOL_SELECTOR"
wait_latest_ready 150 || abort "harness did not reach a ready latest revision before the disconnect assertion"

kubectl delete deploy "$WORKER_DEPLOY" -n "$NS" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
presence_gone=0
for _i in $(seq 1 20); do
  if ! kubectl exec deploy/redis -n "$NS" -- redis-cli HGETALL sh:sandbox:records 2>/dev/null | grep -qF "$SANDBOX_ID"; then
    presence_gone=1; break
  fi
  sleep 2
done
[ "$presence_gone" = 1 ] && ok "presence record for $SANDBOX_ID cleared when the worker's Attach stream closed" \
  || ko "presence record for $SANDBOX_ID survived the worker's deletion (stream-close teardown did not propagate)"

# SH_REMOTE_SANDBOX is still 1 and SH_RELAY_ADDR still points at a live relay with no
# worker parked behind it. A leaf must now come back on the pod path: Alpine => FLAGGED.
resp_disconnect="$(dispatch_pattern "relay-smoke-disconnect-$$" "Alpine")"
assert_verdict "disconnect/Alpine" "$resp_disconnect" "FLAGGED" \
  "with the worker gone the leaf must re-lease an Alpine sandbox pod and complete; an empty or non-FLAGGED verdict means it hung on the dead grpc record or failed instead of retrying"

# --- Restore the harness env, then a control run: with the pool path restored, Alpine
# must be FLAGGED again -- proving both the contrast and that the restore worked. ---
claim "Restore harness env, control run (Alpine must be FLAGGED again)"
restore_harness_env
wait_latest_ready 150 || abort "harness did not reach a ready latest revision after restoring the env"
resp_control="$(dispatch_pattern "relay-smoke-control-$$" "Alpine")"
assert_verdict "control/Alpine" "$resp_control" "FLAGGED" \
  "a CLEAR verdict here means the env restore did not take effect (still on the remote path)"

# --- Teardown the relay. The worker was already deleted by the disconnect assertion
# above, so re-asserting presence-gone here would be a tautology; retarget on the
# relay, which is what this teardown step actually removes. ---
claim "Teardown relay, assert it is removed"
teardown_relay_and_worker
kubectl get deploy sandbox-relay -n "$NS" >/dev/null 2>&1 \
  && ko "deploy/sandbox-relay still present after teardown" \
  || ok "deploy/sandbox-relay removed after teardown"

if [ "$BUILT_IMAGE" = 1 ]; then
  echo "NOTE: locally built worker image $WORKER_IMAGE was not removed from the kind node or the local docker daemon (harmless; re-run to overwrite)."
fi

echo ""; echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then echo "RELAY LEAF SMOKE FAIL"; exit 1; else echo "RELAY LEAF SMOKE PASS"; exit 0; fi
