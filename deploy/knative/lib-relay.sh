#!/usr/bin/env bash
# deploy/knative/lib-relay.sh
# Shared assertions for the remote-sandbox (gRPC relay + worker) proofs.
#
# Sourced by BOTH the gated conformance smoke (relay-leaf-smoke.sh, worker as an
# in-cluster pod) and the laptop demo (demo-remote-worker.sh, worker as a host
# container). Everything here is worker-topology-agnostic on purpose: the two callers
# differ only in WHERE the worker runs and HOW its /etc/os-release is read, so the
# assertions that decide whether the proof holds must not be duplicated between them.
# A drifting copy would let one path keep asserting something the other no longer does.
#
# Source AFTER lib.sh -- this file builds on NS/KSVC/BASE/CURL_OPTS/CURL_HDR and ok/ko.
#
# shellcheck shell=bash

# Model used for the leaf's verdict call. Owned here so both callers agree.
MODEL="${MODEL:-${SH_MODEL:-claude-haiku-4-5}}"

# Harness env flip bookkeeping. Callers must not set these directly: snapshot_harness_env
# fills SH_ENV_SNAPSHOT, flip_harness_env raises SH_ENV_FLIPPED, restore_harness_env
# clears it. Kept as globals (not passed around) so an EXIT trap can restore with no args.
SH_ENV_SNAPSHOT=""
SH_ENV_FLIPPED=0

# --- Output helpers -------------------------------------------------------------------
# claim: announce the step about to be proven. abort: unrecoverable, exit non-zero.
claim() { echo ""; echo "--- $1 ---"; }
abort() { echo "ABORT: $1" >&2; exit 1; }

# --- Revision readiness ----------------------------------------------------------------
# Wait until the ksvc's latest-created revision is also its latest-ready revision (or
# timeout). lib.sh's wait_ksvc_ready swallows failures by design (`|| true`); this adds a
# hard check specifically for the flip/restore transitions, where serving the wrong
# revision would mean asserting against the wrong backend.
# Usage: wait_latest_ready [timeoutSec]
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

# --- Pool selector introspection -------------------------------------------------------
# Echo the pool selector the harness is currently configured with, falling back to the
# setup-kind.sh/setup-ocp.sh default when the env var is absent.
resolve_pool_selector() {
  local sel
  sel="$(kubectl get ksvc "$KSVC" -n "$NS" -o json 2>/dev/null \
    | jq -r '.spec.template.spec.containers[0].env[]? | select(.name=="KAGENTI_SANDBOX_POOL_SELECTOR") | .value' 2>/dev/null || true)"
  echo "${sel:-sh.kagenti.io/sandbox-pool=default}"
}

# Echo the number of Running pods matching a label selector.
# Usage: count_pool_pods <selector>
count_pool_pods() {
  kubectl get pods -n "$NS" -l "$1" --field-selector=status.phase=Running --no-headers 2>/dev/null \
    | wc -l | tr -d ' '
}

# Echo the name of the first Running pod matching a label selector (empty if none).
# Usage: first_pool_pod <selector>
first_pool_pod() {
  kubectl get pods -n "$NS" -l "$1" --field-selector=status.phase=Running --no-headers 2>/dev/null \
    | awk 'NR==1{print $1}'
}

# Assert a selector matches ZERO Running pods. This is what makes the "exec landed on a
# pod" trap structurally impossible rather than merely detectable: select-sandbox.ts
# builds candidates = [...pods, ...grpcRecs], so with no pods in the candidate set its
# least-loaded-first leasing has nothing to route around the worker with. Abort (not ko)
# on a miss -- the remote assertions would silently prove nothing.
# Usage: assert_no_pods_match <selector>
assert_no_pods_match() {
  local sel="$1" n
  n="$(count_pool_pods "$sel")"
  if [ "${n:-0}" -eq 0 ]; then
    ok "pool selector '$sel' matches 0 Running pods -- the remote worker is the only lease candidate"
  else
    abort "pool selector '$sel' matches $n Running pod(s); a pod could win the lease and the remote proof would be vacuous. Refusing to continue."
  fi
}

# --- Presence (the worker's live Attach stream IS its registration) --------------------
# Poll Redis until the sandbox id appears with transport=grpc. Registration happens
# asynchronously after the worker starts -- a worker has no readiness signal an HTTP/TCP
# probe could observe, so "the process is up" never means "it has registered".
# Usage: assert_presence <sandboxId> [attempts]
assert_presence() {
  local sid="$1" attempts="${2:-20}" presence="" i
  for ((i = 0; i < attempts; i++)); do
    presence="$(kubectl exec deploy/redis -n "$NS" -- redis-cli HGETALL sh:sandbox:records 2>/dev/null || true)"
    if echo "$presence" | grep -qF "$sid" && echo "$presence" | grep -q '"transport":"grpc"'; then
      ok "worker $sid present in sh:sandbox:records with transport=grpc"
      return 0
    fi
    sleep 2
  done
  ko "worker $sid not found (or wrong transport) in sh:sandbox:records; presence dump: $(echo "$presence" | head -c 300)"
  return 1
}

# Poll Redis until the sandbox id is GONE -- the stream-close teardown path.
# Usage: assert_presence_gone <sandboxId> [attempts]
assert_presence_gone() {
  local sid="$1" attempts="${2:-20}" i
  for ((i = 0; i < attempts; i++)); do
    if ! kubectl exec deploy/redis -n "$NS" -- redis-cli HGETALL sh:sandbox:records 2>/dev/null | grep -qF "$sid"; then
      ok "presence record for $sid cleared when the worker's Attach stream closed"
      return 0
    fi
    sleep 2
  done
  ko "presence record for $sid survived the worker going away (stream-close teardown did not propagate)"
  return 1
}

# --- Relay health -----------------------------------------------------------------------
# Diagnose a relay that is Running but not serving, and abort with the cause. `kubectl
# rollout status` returns Ready as soon as the pod is Running -- relay-deployment.yaml
# declares no readinessProbe, because a relay's real readiness is "a worker's Attach stream
# is parked here", which no HTTP/TCP probe could observe. So a relay that dies before
# binding :8443 still passes rollout, and the failure resurfaces much later as an
# inexplicable connection error pointing at the network instead of at the relay.
#
# Call this the moment something cannot reach the relay, so the cause is named where it is
# still legible. Usage: diagnose_relay_crash <context-message>
diagnose_relay_crash() {
  local ctx="$1" pod restarts last
  pod="$(kubectl get pods -n "$NS" -l app=sandbox-relay -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || abort "$ctx -- and there is no sandbox-relay pod at all (was relay-deployment.yaml applied?)"
  restarts="$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)"
  last="$(kubectl get pod "$pod" -n "$NS" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)"
  # OOMKilled is the failure this repo has actually hit: a 128Mi limit against ~225 MiB of
  # node+tsx startup. Name it and its fix rather than reporting a generic crash.
  if [ "$last" = "OOMKilled" ]; then
    abort "$ctx -- relay pod $pod is being OOMKilled (restarts=$restarts), so it never bound :8443. Raise the memory limit in relay-deployment.yaml: node+tsx needs ~225 MiB just to idle."
  fi
  if [ "${restarts:-0}" -gt 0 ]; then
    abort "$ctx -- relay pod $pod has restarted $restarts time(s) (lastState=${last:-unknown}); it is not serving. Inspect: kubectl logs $pod -n $NS --previous"
  fi
  abort "$ctx -- relay pod $pod reports no restarts, so the relay process is up but unreachable on the path tried. Inspect: kubectl logs $pod -n $NS"
}

# --- Discriminator ---------------------------------------------------------------------
# Verify the Alpine/RHEL fingerprint BEFORE anything relies on it. The in-cluster sandbox
# pool runs Alpine (sandbox-pool.yaml); the worker image runs RHEL
# (registry.access.redhat.com/ubi9/ubi-minimal). A leaf grepping /etc/os-release for
# "Alpine" is therefore FLAGGED on a pod and CLEAR on the worker, and the reverse for
# "Red Hat" -- so asserting BOTH catches a pod-landed exec either way.
#
# Takes the two os-release texts as STRINGS rather than fetching them: the gate reads the
# worker via `kubectl exec` and the demo via `docker exec`, but the assertion that decides
# whether the discriminator is trustworthy must be identical.
# Usage: validate_discriminator <podOsText> <workerOsText> <podLabel> <workerLabel>
validate_discriminator() {
  local pod_os="$1" worker_os="$2" pod_label="$3" worker_label="$4"
  if echo "$pod_os" | grep -qi 'Alpine' && ! echo "$pod_os" | grep -qi 'Red Hat' \
     && echo "$worker_os" | grep -qi 'Red Hat' && ! echo "$worker_os" | grep -qi 'Alpine'; then
    ok "discriminator holds: sandbox pod ($pod_label)=Alpine, worker ($worker_label)=Red Hat"
  else
    abort "discriminator invalid -- sandbox pod /etc/os-release: [$pod_os]; worker /etc/os-release: [$worker_os]. Refusing to run assertions that would be meaningless without a verified discriminator."
  fi
}

# --- Leaf dispatch + verdict assertion -------------------------------------------------
# dispatch_pattern <sessionId> <pattern> -> echoes terminal JSON from POST /runs, grepping
# /etc/os-release for <pattern>. Mirrors leaf-smoke.sh's dispatch_item curl invocation.
dispatch_pattern() {
  local sid="$1" pat="$2" body
  body=$(jq -nc --arg s "$sid" --arg m "$MODEL" --arg p "$pat" \
    '{sessionId:$s, model:$m, item:{item_id:"i1", file:"/etc/os-release", pattern:$p}}')
  # shellcheck disable=SC2086  # CURL_OPTS is intentionally word-split
  # `|| true`: a connection-level failure (timeout, connection refused) must not exit
  # the caller under set -e here -- it should instead yield an empty body so
  # assert_verdict's "model endpoint unreachable" hint is reached instead of bypassed.
  curl -s $CURL_OPTS --max-time 120 ${CURL_HDR[@]+"${CURL_HDR[@]}"} \
    -H "Content-Type: application/json" -d "$body" "$BASE/runs" || true
}

# assert_verdict <label> <response-json> <want CLEAR|FLAGGED> <hint-if-wrong>
assert_verdict() {
  local label="$1" resp="$2" want="$3" hint="$4" status verdict
  status="$(jq -r '.status // empty' <<<"$resp" 2>/dev/null || true)"
  if [ -z "$status" ]; then
    # Two very different causes look identical here: the harness endpoint not answering
    # (no kourier port-forward / wrong Host header) and the harness answering but the model
    # being unreachable. Name both -- callers that can rule the first out should assert the
    # endpoint up front instead of leaving it to this message.
    ko "$label: no verdict returned (empty/non-JSON response -- either the harness endpoint at $BASE is unreachable, or the model is; check the kourier port-forward, then the llm-credentials secret / SH_MODEL); raw: $(echo "$resp" | head -c 200)"
    return
  fi
  verdict="$(jq -r '.verdict.verdict // empty' <<<"$resp" 2>/dev/null || true)"
  if [ "$verdict" = "$want" ]; then
    ok "$label: verdict=$verdict (expected $want)"
  else
    ko "$label: verdict=$verdict, expected $want -- $hint"
  fi
}

# Echo the model's own stated reason for a verdict (empty when absent). The reason names
# the OS the model actually read, which is what makes the A/B convincing rather than
# merely green -- a verdict alone can't show WHICH filesystem answered.
# Usage: verdict_reason <response-json>
verdict_reason() {
  jq -r '.verdict.reason // empty' <<<"$1" 2>/dev/null || true
}

# --- Harness env flip / restore --------------------------------------------------------
# Capture the harness ksvc env exactly, for exact restore later.
snapshot_harness_env() {
  SH_ENV_SNAPSHOT="$(kubectl get ksvc "$KSVC" -n "$NS" -o json | jq -c '.spec.template.spec.containers[0].env // []')"
  [ -n "$SH_ENV_SNAPSHOT" ] && [ "$SH_ENV_SNAPSHOT" != "null" ] \
    || abort "failed to capture the current harness ksvc env"
  echo "captured $(echo "$SH_ENV_SNAPSHOT" | jq 'length') env entries"
}

# Apply env changes via lib.sh's set_ksvc_env and mark the harness as flipped so the EXIT
# trap knows a restore is owed. Usage: flip_harness_env NAME=value [NAME=value ...]
flip_harness_env() {
  set_ksvc_env "$@"
  SH_ENV_FLIPPED=1
}

# Exact-restore the harness env from the snapshot. Idempotent: a no-op once SH_ENV_FLIPPED
# is cleared, so both the normal flow and the EXIT trap can call it safely. Leaving the
# harness flipped -- pointed at a selector matching nothing -- is the worst outcome either
# caller could produce, so this must run even on an interrupted run.
restore_harness_env() {
  [ "$SH_ENV_FLIPPED" = 1 ] || return 0
  [ -n "$SH_ENV_SNAPSHOT" ] || return 0
  echo "restoring harness env to pre-flip snapshot..."
  if kubectl patch ksvc "$KSVC" -n "$NS" --type=json \
       -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":$SH_ENV_SNAPSHOT}]" \
       >/dev/null 2>&1; then
    wait_ksvc_ready
    SH_ENV_FLIPPED=0
    echo "harness env restored"
  else
    echo "WARN: restore patch failed; leaving SH_ENV_FLIPPED set so the EXIT trap retries (inspect with kubectl get ksvc/$KSVC -o json)" >&2
  fi
}
