#!/usr/bin/env bash
# Keep the BugStone demo dashboard open and follow each new Act 1/2 run.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_VENV="$DEMO_DIR/.bugstone/dashboard-venv"
BUGSTONE_PY="$DEMO_DIR/.bugstone/BugStoneSkills/venv/bin/python3"

if [ -x "$BUGSTONE_PY" ] && "$BUGSTONE_PY" -c 'import click, rich' 2>/dev/null; then
  DASHBOARD_PY="$BUGSTONE_PY"
elif [ ! -x "$DASHBOARD_VENV/bin/python3" ]; then
  echo "--- first run: create dashboard environment ---"
  mkdir -p "$DEMO_DIR/.bugstone"
  python3 -m venv "$DASHBOARD_VENV"
  DASHBOARD_PY="$DASHBOARD_VENV/bin/python3"
else
  DASHBOARD_PY="$DASHBOARD_VENV/bin/python3"
fi
if ! "$DASHBOARD_PY" -c 'import click, rich' 2>/dev/null; then
  echo "--- first run: install dashboard dependencies ---"
  "$DASHBOARD_PY" -m pip install -q -r "$DEMO_DIR/dashboard-requirements.txt"
fi

exec "$DASHBOARD_PY" "$DEMO_DIR/dashboard.py" \
  --log-dir "$DEMO_DIR/.bugstone/logs" \
  --context "${KUBE_CONTEXT:-agentic-cloud}" \
  --namespace "${KAGENTI_NS:-serverless-harness}" \
  --service "${KAGENTI_KSVC:-serverless-harness}" \
  --pool-selector "${KAGENTI_POOL_SELECTOR:-sh.kagenti.io/sandbox-pool=default}" \
  --interval "${INTERVAL:-2}" \
  --watch
