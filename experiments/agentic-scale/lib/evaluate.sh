#!/usr/bin/env bash
# Plan D — Stage 2: offline SWE-bench evaluator.  Scores captured predictions.jsonl -> resolved-rate.
#
# MODEL-FREE and CLUSTER-FREE: it applies each captured `model_patch` to the repo at base_commit
# and runs the gold FAIL_TO_PASS / PASS_TO_PASS tests inside the official per-instance Docker
# container, then reports how many bugs the patches actually fixed. No LLM, no OpenShift, no Knative.
#
# arm64 note: the official eval images are published x86_64-only (swebench/sweb.eval.x86_64.<id>).
# We pull those prebuilt images from the namespace encoded by the dataset (no local build) and run
# them under Docker's amd64 emulation. All instances in the captured
# deck are pure-python, so emulated test runs are correct (just slower); C-extension repos would
# need a native x86 host.
#
# Env knobs: RUN_ID, DATASET, MAX_WORKERS, INSTANCE_IDS (space-separated subset for a smoke),
#            PRED_A / PRED_B (input prediction files), LOG_DIR, VENV.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWEBENCH_DIR="$(cd "$SCRIPT_DIR/../../swebench" && pwd)"

LOG_DIR="${LOG_DIR:-/tmp/kagenti/planD}"; mkdir -p "$LOG_DIR"
VENV="${VENV:-$LOG_DIR/.venv-swebench}"
RUN_ID="${RUN_ID:-haiku-baseline}"
DATASET="${DATASET:-SWE-bench/SWE-bench_Verified}"
MAX_WORKERS="${MAX_WORKERS:-2}"          # emulated x86 is slow -> keep concurrency low
PRED_A="${PRED_A:-/tmp/kagenti/planC/authrun/predictions.jsonl}"
PRED_B="${PRED_B-/tmp/kagenti/planC/authrun/predictions-e1.jsonl}"
MERGED="${MERGED:-$LOG_DIR/predictions-merged.jsonl}"
HF_HOME="${HF_HOME:-/tmp/swebench-huggingface}"
export HF_HOME

echo "[evaluate] run_id=$RUN_ID dataset=$DATASET workers=$MAX_WORKERS log_dir=$LOG_DIR"

# 1. tooling: venv + official swebench harness
if [ ! -x "$VENV/bin/python" ]; then
  echo "[evaluate] creating venv $VENV"
  python3 -m venv "$VENV"
fi
if "$VENV/bin/pip" install -q --upgrade pip swebench >"$LOG_DIR/pip.log" 2>&1; then
  echo "[evaluate] swebench installed ($("$VENV/bin/python" -c 'import swebench; print(swebench.__version__)' 2>/dev/null || echo '?'))"
else
  echo "[evaluate] pip install FAILED (see $LOG_DIR/pip.log)"; exit 1
fi

# 2. merge + dedup captured predictions into one official-shape file
PRED_INPUTS=("$PRED_A")
[ -n "$PRED_B" ] && PRED_INPUTS+=("$PRED_B")
"$VENV/bin/python" "$SWEBENCH_DIR/merge_predictions.py" "$MERGED" "${PRED_INPUTS[@]}"

# 3. docker must be up; use amd64 emulation for the x86 eval images
docker info >/dev/null 2>&1 || { echo "[evaluate] Docker daemon not running"; exit 1; }
export DOCKER_DEFAULT_PLATFORM="${DOCKER_DEFAULT_PLATFORM:-linux/amd64}"
echo "[evaluate] DOCKER_DEFAULT_PLATFORM=$DOCKER_DEFAULT_PLATFORM"

# The Python Docker SDK used by SWE-bench does not honor DOCKER_DEFAULT_PLATFORM while pulling.
# On an ARM host, pre-pull each required x86 image explicitly; the evaluator then finds it locally.
if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
  echo "[evaluate] pre-pulling required images for $DOCKER_DEFAULT_PLATFORM"
  while IFS= read -r image; do
    [ -n "$image" ] || continue
    # Avoid making a working offline evaluation depend on Docker Hub. Reuse the local image only
    # when it is the required amd64 build; otherwise pull it and surface a useful failure message.
    if [ "$(docker image inspect "$image" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null || true)" = "$DOCKER_DEFAULT_PLATFORM" ]; then
      echo "[evaluate] using local $DOCKER_DEFAULT_PLATFORM image: $image"
    elif ! docker pull --platform "$DOCKER_DEFAULT_PLATFORM" "$image"; then
      echo "[evaluate] failed to pull required image: $image" >&2
      echo "[evaluate] retry the command when Docker Hub is reachable" >&2
      exit 1
    fi
  done < <("$VENV/bin/python" - "$DATASET" "$MERGED" <<'PY'
import json
import sys

from datasets import load_dataset

dataset_name, predictions_path = sys.argv[1:]
with open(predictions_path) as f:
    wanted = {json.loads(line)["instance_id"] for line in f if line.strip()}
rows = load_dataset(dataset_name, split="test")
for image in sorted({row["image"] for row in rows if row["instance_id"] in wanted}):
    print(image)
PY
  )
fi

# optional subset (smoke)
IID_ARGS=()
if [ -n "${INSTANCE_IDS:-}" ]; then
  # shellcheck disable=SC2206
  IID_ARGS=(--instance_ids ${INSTANCE_IDS})
  echo "[evaluate] subset: $INSTANCE_IDS"
fi

# 4. run the official evaluator from LOG_DIR so its report + logs/ land there (not in the repo)
echo "[evaluate] running swebench.harness.run_evaluation -> $LOG_DIR/eval-$RUN_ID.log"
NAMESPACE_ARGS=()
# SWE-bench <5 required this option. In 5.x the image namespace comes from the dataset and the
# option was removed, so pass it only when supported.
if "$VENV/bin/python" -m swebench.harness.run_evaluation --help 2>&1 | grep -q -- '--namespace'; then
  NAMESPACE_ARGS=(--namespace swebench)
fi
( cd "$LOG_DIR" && "$VENV/bin/python" -m swebench.harness.run_evaluation \
    --dataset_name "$DATASET" \
    --predictions_path "$MERGED" \
    --run_id "$RUN_ID" \
    "${NAMESPACE_ARGS[@]}" \
    --max_workers "$MAX_WORKERS" \
    "${IID_ARGS[@]}" ) >"$LOG_DIR/eval-$RUN_ID.log" 2>&1
echo "EVAL_EXIT:$? (full log: $LOG_DIR/eval-$RUN_ID.log)"

# 5. summarize
"$VENV/bin/python" "$SWEBENCH_DIR/summarize_report.py" "$RUN_ID" "$LOG_DIR"
