#!/usr/bin/env bash
# demo/gpfs-scale/run-bugstone.sh
# Drive BugStone Act 1 (sync) or Act 2 (async) against the live agentic-cloud
# cluster, for the GPFS/Storage Scale shared-agent-context demo. Thin wrapper
# around BugStone's own RUNBOOK.md commands — see that file for the underlying
# details/troubleshooting.
#
# Usage: ./run-bugstone.sh act1|act2 [fixture]
set -euo pipefail

BUGSTONE_DIR="${BUGSTONE_DIR:-$HOME/ResilioSync/github.ibm.com/dettori/BugStoneSkills}"
FIXTURE="${2:-tests/fixtures/smoke-python}"
ACT="${1:-}"

case "$ACT" in
  act1|act2) ;;
  *)
    echo "Usage: $0 act1|act2 [fixture]" >&2
    exit 1
    ;;
esac

if [ ! -d "$BUGSTONE_DIR" ]; then
  echo "BugStone checkout not found at $BUGSTONE_DIR (set BUGSTONE_DIR to override)" >&2
  exit 1
fi

cd "$BUGSTONE_DIR"
kubectl config use-context agentic-cloud >/dev/null
# shellcheck disable=SC1091  # generated env file, not available at lint time
source .jacohn/serverless-harness/agentic-cloud.env

echo "--- pre-flight: is agentic-cloud up? ---"
kubectl -n serverless-harness get ksvc serverless-harness
kubectl -n serverless-harness get pods | grep -E 'redis|gitd|sandbox' || true
echo

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

echo
echo "--- verify ---"
# shellcheck disable=SC2012  # results/run-* names are timestamp-safe, ls -t is fine here
R=$(ls -dt results/run-* | head -1)
python3 -c "import json;print('passed=',json.load(open('$R/phase_b/completion_audit.json'))['passed'])"
echo "report: $R/report.html"
