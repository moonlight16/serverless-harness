#!/usr/bin/env bash
# demo/gpfs-scale/run-bugstone.sh
# Drive BugStone Act 1 (sync) or Act 2 (async) against the IBM Cloud
# agentic-node cluster used for the GPFS/Storage Scale demo.
#
# Usage: [MODEL=model-name] ./run-bugstone.sh act1|act2 [fixture]
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUGSTONE_REPO="${BUGSTONE_REPO:-https://github.ibm.com/dettori/BugStoneSkills.git}"
BUGSTONE_BRANCH="${BUGSTONE_BRANCH:-feat/archetype-a-serverless-harness-poc}"
BUGSTONE_DIR="${BUGSTONE_DIR:-$DEMO_DIR/.bugstone/BugStoneSkills}"
BUGSTONE_ENV_FILE="${BUGSTONE_ENV_FILE:-}"
FIXTURE="${2:-tests/fixtures/smoke-python}"
ACT="${1:-}"

case "$ACT" in
  act1|act2) ;;
  *)
    echo "Usage: $0 act1|act2 [fixture]" >&2
    exit 1
    ;;
esac

if [ ! -e "$BUGSTONE_DIR" ]; then
  echo "--- first run: clone BugStone ($BUGSTONE_BRANCH) ---"
  mkdir -p "$(dirname "$BUGSTONE_DIR")"
  git clone --branch "$BUGSTONE_BRANCH" --single-branch "$BUGSTONE_REPO" "$BUGSTONE_DIR"
fi

if [ ! -f "$BUGSTONE_DIR/agent_specifics/serverless_harness/run_poc.sh" ]; then
  echo "BugStone checkout at $BUGSTONE_DIR does not contain the serverless-harness adapter" >&2
  exit 1
fi

# The remote demo branch lacks the external-gateway support used by agentic-cloud.
# Apply the small compatibility patch once; accept an already-patched checkout.
BUGSTONE_PATCH="$DEMO_DIR/bugstone-external-cluster.patch"
if git -C "$BUGSTONE_DIR" apply --check "$BUGSTONE_PATCH" 2>/dev/null; then
  echo "--- apply BugStone external-cluster support ---"
  git -C "$BUGSTONE_DIR" apply "$BUGSTONE_PATCH"
elif ! git -C "$BUGSTONE_DIR" apply --reverse --check "$BUGSTONE_PATCH" 2>/dev/null; then
  echo "BugStone external-cluster patch does not apply cleanly to $BUGSTONE_DIR" >&2
  exit 1
fi

cd "$BUGSTONE_DIR"

if [ ! -x venv/bin/python3 ]; then
  echo "--- first run: set up BugStone ---"
  bash setup.sh
fi
# BugStone's runtime profile launches workers with plain `python3`; ensure those
# subprocesses resolve to this checkout's fully provisioned virtual environment.
export PATH="$BUGSTONE_DIR/venv/bin:$PATH"

if [ -n "$BUGSTONE_ENV_FILE" ]; then
  if [ ! -f "$BUGSTONE_ENV_FILE" ]; then
    echo "BugStone environment file not found: $BUGSTONE_ENV_FILE" >&2
    exit 1
  fi
  # shellcheck disable=SC1090  # user-supplied local environment file
  source "$BUGSTONE_ENV_FILE"
fi

# Defaults for the IBM Cloud agentic-node demo environment. Each can still be
# overridden by an exported variable or BUGSTONE_ENV_FILE.
KUBE_CONTEXT="${KUBE_CONTEXT:-agentic-cloud}"
export KAGENTI_CLUSTER="${KAGENTI_CLUSTER:-external}"
export KAGENTI_BASE="${KAGENTI_BASE:-https://serverless-harness.163-75-85-180.sslip.io}"
export KAGENTI_TLS_VERIFY="${KAGENTI_TLS_VERIFY:-1}"
export KAGENTI_AUTH_HEADER="${KAGENTI_AUTH_HEADER:-x-sh-auth}"
export KAGENTI_NS="${KAGENTI_NS:-serverless-harness}"
export KAGENTI_KSVC="${KAGENTI_KSVC:-serverless-harness}"
export KAGENTI_POOL_SELECTOR="${KAGENTI_POOL_SELECTOR:-sh.kagenti.io/sandbox-pool=default}"

# Use one public knob for both dispatch paths: Act 1 reads BUGSTONE_PHASE_B_MODEL;
# Act 2 reads KAGENTI_MODEL.
MODEL="${MODEL:-${KAGENTI_MODEL:-${BUGSTONE_PHASE_B_MODEL:-meta-llama/Llama-3.3-70B-Instruct}}}"
export KAGENTI_MODEL="$MODEL"
export BUGSTONE_PHASE_B_MODEL="$MODEL"

kubectl config use-context "$KUBE_CONTEXT" >/dev/null

# The demo gateway stores its accepted x-sh-auth value in this policy.
if [ -z "${KAGENTI_AUTH_VALUE:-}" ]; then
  KAGENTI_AUTH_VALUE="$(
    kubectl --context "$KUBE_CONTEXT" -n kagenti-system get authorizationpolicy \
      serverless-harness-require-header \
      -o jsonpath='{.spec.rules[0].when[0].notValues[0]}'
  )"
  export KAGENTI_AUTH_VALUE
fi

echo "--- pre-flight: is $KUBE_CONTEXT up? ---"
echo "model: $MODEL"
kubectl -n serverless-harness get ksvc serverless-harness
kubectl -n serverless-harness get pods | grep -E 'redis|gitd|sandbox' || true
echo

run_workload() {
  case "$ACT" in
    act1)
      echo "--- Act 1 (sync): $FIXTURE ---"
      bash agent_specifics/serverless_harness/run_poc.sh "$FIXTURE"
      ;;
    act2)
      echo "--- Act 2 (async): $FIXTURE ---"
      bash agent_specifics/serverless_harness/run_poc_async.sh "$FIXTURE"
      ;;
  esac
}

mkdir -p "$DEMO_DIR/.bugstone/logs"
RUN_LOG="$DEMO_DIR/.bugstone/logs/${ACT}-$(date +%Y%m%d-%H%M%S).log"
RUN_STATUS_FILE="$RUN_LOG.status"
printf 'act=%s\nmodel=%s\nstarted=%s\n' "$ACT" "$MODEL" "$(date +%s)" >"$RUN_LOG.meta"

set +e
run_workload 2>&1 | tee "$RUN_LOG"
RUN_STATUS=${PIPESTATUS[0]}
set -e
printf '%s\n' "$RUN_STATUS" >"$RUN_STATUS_FILE"

echo
echo "full log: $RUN_LOG"
if [ "$RUN_STATUS" -ne 0 ]; then
  echo "BugStone $ACT failed (exit $RUN_STATUS)" >&2
  exit "$RUN_STATUS"
fi

echo
echo "--- verify ---"
# shellcheck disable=SC2012  # results/run-* names are timestamp-safe, ls -t is fine here
R=$(ls -dt results/run-* | head -1)
python3 -c "import json;print('passed=',json.load(open('$R/phase_b/completion_audit.json'))['passed'])"
echo "report: $R/report.html"
