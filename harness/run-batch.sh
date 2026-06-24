#!/usr/bin/env bash
# Batch runner. Iterates (arm, task) combinations and dispatches harness/run.sh
# in parallel. Resumes by skipping (arm, task) pairs that already have a
# non-empty submission.tar.gz.
#
# Usage:
#   run-batch.sh --arms <a1,a2,...> [task selector] [--run-name N]
#                [--parallel N] [--budget USD] [--model M]
#                [--keep-image] [--max-retries N]
#
# Task selector (pick one):
#   --tasks <id,id,...>      explicit task ids
#   --slice <a:b>            sorted task list, slice [a:b)
#   --filter <regex>         posix regex on task ids
#   (none)                   all 201 tasks
#
# Examples:
#   ./harness/run-batch.sh --arms vanilla,gstack-curated --slice 0:10 \
#       --run-name pilot --parallel 3 --budget 8
#
#   ./harness/run-batch.sh --arms gstack-curated --tasks abishekvashok__cmatrix.5c082c6 \
#       --run-name smoke --parallel 1
#
# Determinism: task list is sorted lexicographically before slicing so
# --slice 0:10 picks the same 10 tasks every time. Per-task work is dispatched
# to harness/run.sh which handles its own isolation.

set -euo pipefail

ARMS_RAW=""
TASKS_RAW=""
SLICE=""
FILTER=""
RUN_NAME="${PB_RUN_NAME:-default}"
PARALLEL=2   # default agent concurrency (2026-06-22; lowered from 4). parallel=4 exhausted the Codex gpt-5.5 ROLLING usage quota mid-run (capped after ~169/200 tasks) because 4 concurrent agents burn the window faster than it replenishes; parallel=2 halves the burn rate to stay under it. Still REQUIRES `docker login` (200/6hr) to avoid 429 pull-cascade false-failures. Override with --parallel 1 for anonymous runs, or --parallel 4 only when quota headroom is known-ample (ask first).
BUDGET="${PB_BUDGET_USD:-50}"
MODEL="${PB_MODEL:-}"   # empty → let per-arm runner pick its own default (claude-* defaults to claude-opus-4-7, codex-* defaults to gpt-5.5)
KEEP_IMAGE_FLAG=""
MAX_RETRIES=1
MIN_VALID_BYTES=200   # smaller submissions are the empty-tar sentinel and get retried

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arms) ARMS_RAW="$2"; shift 2 ;;
    --tasks) TASKS_RAW="$2"; shift 2 ;;
    --slice) SLICE="$2"; shift 2 ;;
    --filter) FILTER="$2"; shift 2 ;;
    --run-name) RUN_NAME="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --budget) BUDGET="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --keep-image) KEEP_IMAGE_FLAG="--keep-image"; shift 1 ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$ARMS_RAW" ]] && { echo "missing --arms" >&2; exit 2; }
IFS=',' read -ra ARMS <<< "$ARMS_RAW"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO/harness/run.sh"
CODEX_RUNNER="$REPO/harness/run-codex.sh"
[[ -x "$RUNNER" ]] || { echo "harness/run.sh missing or not executable" >&2; exit 2; }

# Pick which per-task runner to use for a given arm. Codex arms (`codex-*`)
# dispatch to run-codex.sh; everything else uses the Claude run.sh. Keep the
# arm-name prefix convention so new harnesses can opt in without flag churn.
runner_for_arm() {
  case "$1" in
    codex-*) echo "$CODEX_RUNNER" ;;
    *)       echo "$RUNNER" ;;
  esac
}

# Validate arms exist
for arm in "${ARMS[@]}"; do
  [[ -d "$REPO/arms/$arm" ]] || { echo "arm not found: $arm" >&2; exit 2; }
done

# Resolve task list. Prefer the venv's bundled task dir; fall back to importing
# programbench so this still works if the user moved the venv around.
TASKS_DIR="$REPO/cache/pb-venv/lib/python3.11/site-packages/programbench/data/tasks"
if [[ ! -d "$TASKS_DIR" ]]; then
  TASKS_DIR="$(python3 -c 'import programbench.constants as c; print(c.TASKS_DIR)' 2>/dev/null || echo "")"
  [[ -d "$TASKS_DIR" ]] || { echo "can't find programbench task dir; install it via uv pip install programbench" >&2; exit 2; }
fi

# Tasks excluded from every run regardless of selector. These are tasks shipped
# with programbench that aren't real benchmark instances (e.g. synthetic
# fixtures without a published cleanroom image on Docker Hub). Keep this list
# tiny and obvious - if it grows, move to a sibling file.
EXCLUDED_TASKS=(
  testorg__calculator.abc1234   # scaffold/example task, no published cleanroom image
)

is_excluded() {
  local t="$1" x
  for x in "${EXCLUDED_TASKS[@]}"; do
    [[ "$t" == "$x" ]] && return 0
  done
  return 1
}

ALL_TASKS=()
while IFS= read -r line; do ALL_TASKS+=("$line"); done < <(ls "$TASKS_DIR" | sort)
# PB_200_FIX: pre-exclude fixtures BEFORE slicing so --slice indexes the real-task
# list (codex-pilot-2 wants exactly 200, not 201 incl. the testorg scaffold).
_pb200=(); for _t in "${ALL_TASKS[@]}"; do is_excluded "$_t" || _pb200+=("$_t"); done
ALL_TASKS=("${_pb200[@]}")

# Apply selector
TASKS=()
if [[ -n "$TASKS_RAW" ]]; then
  IFS=',' read -ra TASKS <<< "$TASKS_RAW"
elif [[ -n "$SLICE" ]]; then
  IFS=':' read -r a b <<< "$SLICE"
  : "${a:=0}"
  : "${b:=${#ALL_TASKS[@]}}"
  for ((i=a; i<b && i<${#ALL_TASKS[@]}; i++)); do TASKS+=("${ALL_TASKS[$i]}"); done
elif [[ -n "$FILTER" ]]; then
  for t in "${ALL_TASKS[@]}"; do
    [[ "$t" =~ $FILTER ]] && TASKS+=("$t")
  done
else
  TASKS=("${ALL_TASKS[@]}")
fi

# Drop excluded tasks regardless of how they were selected. Anything explicitly
# passed via --tasks gets dropped with a visible note so it's obvious why.
FILTERED_TASKS=()
for t in "${TASKS[@]}"; do
  if is_excluded "$t"; then
    echo "[batch] excluding $t (in EXCLUDED_TASKS; not a real benchmark instance)" >&2
    continue
  fi
  FILTERED_TASKS+=("$t")
done
TASKS=("${FILTERED_TASKS[@]}")

[[ "${#TASKS[@]}" -gt 0 ]] || { echo "no tasks selected" >&2; exit 2; }

echo "[batch] arms=${ARMS[*]}  tasks=${#TASKS[@]}  parallel=$PARALLEL  run=$RUN_NAME  budget=\$$BUDGET"

# Build job list (arm, task) skipping anything already complete
JOBS=()
SKIPPED=0
for arm in "${ARMS[@]}"; do
  for task in "${TASKS[@]}"; do
    out="$REPO/runs/$RUN_NAME/$arm/$task/submission.tar.gz"
    # Resume only if the submission is a real tarball, not the empty-tar
    # failure sentinel (~29 bytes). 200 bytes is well above the sentinel
    # and well below any realistic compile.sh + source submission.
    if [[ -f "$out" ]] && (( $(wc -c <"$out") >= MIN_VALID_BYTES )); then
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    JOBS+=("$arm:$task")
  done
done

echo "[batch] resume: skipping $SKIPPED already-complete jobs; ${#JOBS[@]} to run"
[[ "${#JOBS[@]}" -eq 0 ]] && { echo "[batch] nothing to do."; exit 0; }

# Each child writes its stdout to logs/<run>/_batch/<arm>__<task>.log
mkdir -p "$REPO/logs/$RUN_NAME/_batch"

run_one() {
  local arm="$1" task="$2"
  local logfile="$REPO/logs/$RUN_NAME/_batch/${arm}__${task}.log"
  local attempt=0
  while (( attempt <= MAX_RETRIES )); do
    if [[ "$attempt" -gt 0 ]]; then
      echo "[batch][$arm/$task] retry attempt $attempt" | tee -a "$logfile" >&2
    fi
    local per_arm_runner
    per_arm_runner="$(runner_for_arm "$arm")"
    [[ -x "$per_arm_runner" ]] || { echo "runner missing: $per_arm_runner" | tee -a "$logfile" >&2; return 1; }
    local model_arg=()
    [[ -n "$MODEL" ]] && model_arg=(--model "$MODEL")
    "$per_arm_runner" \
      --arm "$arm" --task "$task" \
      --run-name "$RUN_NAME" \
      --budget "$BUDGET" "${model_arg[@]}" \
      $KEEP_IMAGE_FLAG \
      >> "$logfile" 2>&1
    if [[ -s "$REPO/runs/$RUN_NAME/$arm/$task/submission.tar.gz" ]]; then
      return 0
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# Track completion
COMPLETED=0
FAILED=0
TOTAL=${#JOBS[@]}
START_TS=$(date +%s)

declare -a PIDS=()
declare -A PID_LABEL=()

reap() {
  local pid="$1"
  local label="${PID_LABEL[$pid]}"
  unset "PID_LABEL[$pid]"
  if wait "$pid"; then
    COMPLETED=$((COMPLETED + 1))
    echo "[batch] OK   $label  ($COMPLETED done, $FAILED failed, $((TOTAL - COMPLETED - FAILED)) remaining)"
  else
    FAILED=$((FAILED + 1))
    echo "[batch] FAIL $label  ($COMPLETED done, $FAILED failed, $((TOTAL - COMPLETED - FAILED)) remaining)" >&2
  fi
}

dispatch() {
  local label="$1"
  local arm="${label%%:*}"
  local task="${label##*:}"
  run_one "$arm" "$task" &
  local pid=$!
  PIDS+=("$pid")
  PID_LABEL[$pid]="$arm/$task"
  echo "[batch] >>> $arm/$task (pid $pid)"
}

for label in "${JOBS[@]}"; do
  while (( $(jobs -rp | wc -l) >= PARALLEL )); do
    wait -n || true
    # Reap any finished entries
    new_pids=()
    for pid in "${PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        new_pids+=("$pid")
      else
        reap "$pid"
      fi
    done
    PIDS=("${new_pids[@]}")
  done
  dispatch "$label"
done

# Wait for remaining
for pid in "${PIDS[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    wait "$pid" || true
  fi
  if [[ -n "${PID_LABEL[$pid]:-}" ]]; then
    reap "$pid" || true
  fi
done

ELAPSED=$(( $(date +%s) - START_TS ))
echo
echo "[batch] done in ${ELAPSED}s.  total=$TOTAL  completed=$COMPLETED  failed=$FAILED  skipped=$SKIPPED"
[[ "$FAILED" -gt 0 ]] && exit 1 || exit 0
