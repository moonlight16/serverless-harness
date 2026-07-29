#!/usr/bin/env bash
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$DEMO_DIR/.dashboard"
BUGSTONE_PY="$DEMO_DIR/../gpfs-scale/.bugstone/dashboard-venv/bin/python3"

if [ -x "$BUGSTONE_PY" ] && "$BUGSTONE_PY" -c 'import click, rich' 2>/dev/null; then
  DASHBOARD_PY="$BUGSTONE_PY"
elif [ ! -x "$VENV/bin/python3" ]; then
  echo "--- first run: create dashboard environment ---"
  python3 -m venv "$VENV"
  DASHBOARD_PY="$VENV/bin/python3"
else
  DASHBOARD_PY="$VENV/bin/python3"
fi
if ! "$DASHBOARD_PY" -c 'import click, rich' 2>/dev/null; then
  echo "--- first run: install dashboard dependencies ---"
  "$DASHBOARD_PY" -m pip install -q -r "$DEMO_DIR/dashboard-requirements.txt"
fi

exec "$DASHBOARD_PY" "$DEMO_DIR/dashboard.py" \
  --output-dir "$DEMO_DIR/output" \
  --context "${KUBE_CONTEXT:-agentic-cloud}" \
  --namespace "${NAMESPACE:-serverless-harness}" \
  --interval "${INTERVAL:-1.5}" \
  --watch
