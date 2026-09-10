#!/usr/bin/env bash
# Prepares static Scale-backed PVs for the SWE-bench runner when dynamic Scale provisioning is unavailable.
set -euo pipefail

RUN_ID="${1:?usage: $0 RUN_ID [POOL_SIZE] [SIZE]}"
POOL_SIZE="${2:-1}"
SIZE="${3:-20Gi}"
NS="${NS:-serverless-harness}"
CONTEXT="${CONTEXT:-agentic-cloud}"
SCALE_ROOT="${SCALE_ROOT:-/gpfs/fs1/swebench}"
POOL="swe-$(printf '%s' "$RUN_ID" | tr '[:upper:]_' '[:lower:]-' | cut -c1-48)"
PREP="prepare-${POOL}"
PREP="${PREP:0:63}"

case "$POOL_SIZE" in ''|*[!0-9]*|0) echo "POOL_SIZE must be a positive integer" >&2; exit 2 ;; esac

dirs=""
for i in $(seq 0 $((POOL_SIZE - 1))); do dirs="$dirs $SCALE_ROOT/workspace-$POOL-$i"; done

kubectl --context "$CONTEXT" -n "$NS" delete pod "$PREP" --ignore-not-found --wait=true >/dev/null
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $PREP, namespace: $NS}
spec:
  restartPolicy: Never
  nodeName: agentic-node-2
  containers:
    - name: prepare
      image: busybox:1.36
      command: ["sh", "-c", "mkdir -p$dirs && chmod 0777$dirs"]
      volumeMounts: [{name: scale, mountPath: /gpfs/fs1}]
  volumes:
    - name: scale
      hostPath: {path: /gpfs/fs1, type: Directory}
EOF
kubectl --context "$CONTEXT" -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$PREP" --timeout=60s >/dev/null
kubectl --context "$CONTEXT" -n "$NS" delete pod "$PREP" --wait=true >/dev/null

for i in $(seq 0 $((POOL_SIZE - 1))); do
  claim="workspace-$POOL-$i"
  pv="${POOL}-${i}"
  kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata: {name: $pv}
spec:
  capacity: {storage: $SIZE}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ibm-scale-csi
  claimRef: {namespace: $NS, name: $claim}
  hostPath: {path: $SCALE_ROOT/$claim, type: Directory}
EOF
done

echo "Prepared $POOL_SIZE Scale-backed PV(s) for RUN_ID=$RUN_ID"
