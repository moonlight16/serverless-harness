#!/usr/bin/env bash
# Prepare a static PVC backed by the Scale mount for vLLM's filesystem KV tier.
set -euo pipefail

CONTEXT="${CONTEXT:-agentic-cloud}"
NS="${NS:-llm-d}"
PV="${KV_PV:-nemotron-kv-cache-scale}"
PVC="${KV_PVC:-nemotron-kv-cache-scale}"
SCALE_PATH="${KV_SCALE_PATH:-/gpfs/fs1/kv-cache/nemotron-ultra}"

if kubectl --context "$CONTEXT" -n "$NS" get pvc "$PVC" >/dev/null 2>&1; then
  echo "Scale KV storage ready: $NS/$PVC"
  exit 0
fi

echo "Preparing Scale KV storage: $NS/$PVC"

kubectl --context "$CONTEXT" -n "$NS" delete pod prepare-nemotron-kv-scale \
  --ignore-not-found --wait=true >/dev/null
kubectl --context "$CONTEXT" -n "$NS" run prepare-nemotron-kv-scale \
  --image=busybox:1.36 --restart=Never --overrides="$(jq -nc --arg path "$SCALE_PATH" '{
    spec:{nodeName:"agentic-node-2",containers:[{name:"prepare-nemotron-kv-scale",image:"busybox:1.36",
    command:["sh","-c"],args:["mkdir -p \"$1\" && chmod 0777 \"$1\"","_",$path],
    volumeMounts:[{name:"scale",mountPath:"/gpfs/fs1"}]}],volumes:[{name:"scale",hostPath:{path:"/gpfs/fs1",type:"Directory"}}]}}
  ')" >/dev/null
kubectl --context "$CONTEXT" -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/prepare-nemotron-kv-scale --timeout=60s >/dev/null
kubectl --context "$CONTEXT" -n "$NS" delete pod prepare-nemotron-kv-scale --wait=true >/dev/null

kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata: {name: $PV}
spec:
  capacity: {storage: 7Ti}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ibm-scale-csi
  claimRef: {namespace: $NS, name: $PVC}
  hostPath: {path: $SCALE_PATH, type: Directory}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $PVC, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ibm-scale-csi
  volumeName: $PV
  resources:
    requests: {storage: 7Ti}
EOF
