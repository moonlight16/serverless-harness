#!/usr/bin/env bash
# Create a deterministic multi-repository SWE-bench workload deck.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPOS="${REPOS:-4}"
TASKS="${TASKS:-12}"
AGENTS="${AGENTS:-4}"
SANDBOXES="${SANDBOXES:-4}"
REPEATS="${REPEATS:-1}"
SEED="${SEED:-7}"
OUT="${OUT:-/tmp/agentic-scale-${REPOS}r-${TASKS}t.json}"

for value in "$REPOS" "$TASKS" "$AGENTS" "$SANDBOXES" "$REPEATS"; do
  case "$value" in
    ''|*[!0-9]*|0)
      echo "REPOS, TASKS, AGENTS, SANDBOXES, and REPEATS must be positive integers" >&2
      exit 2
      ;;
  esac
done

python3 "$ROOT/experiments/agentic-scale/lib/select-workload.py" \
  --deck "$ROOT/experiments/swebench/deck.json" \
  --repos "$REPOS" --tasks "$TASKS" --seed "$SEED" --output "$OUT"

cat <<EOF

Load plan
  REPOS=$REPOS       distinct codebases
  TASKS=$TASKS       distinct SWE-bench issues per repetition
  AGENTS=$AGENTS      maximum simultaneous agents
  SANDBOXES=$SANDBOXES  isolated workspaces
  REPEATS=$REPEATS     workload repetitions
  DECK=$OUT

This command selects and records the workload. Multi-repository execution requires the universal
SWE-bench sandbox image because a per-instance image can execute only its matching repository.
EOF
