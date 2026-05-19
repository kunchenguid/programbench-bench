#!/usr/bin/env bash
# Run programbench eval on each arm of a run, then run the analyzer.
# Idempotent: programbench eval skips already-scored submissions.
#
# Usage: score-and-report.sh --run <name> --arms <a,b,...>
#                            [--workers N] [--branch-workers M]
#
# --workers defaults to 4 (was 1 historically; sequential eval is too slow
# at ~30 min/task average, where parallel cuts a 200-task run from ~4 days
# to ~12 hours). --branch-workers defaults to 2. Override either to dial
# back resource usage if eval competes with other workloads.

set -euo pipefail

RUN_NAME=""
ARMS_RAW=""
WORKERS=4
BRANCH_WORKERS=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN_NAME="$2"; shift 2 ;;
    --arms) ARMS_RAW="$2"; shift 2 ;;
    --workers|-w) WORKERS="$2"; shift 2 ;;
    --branch-workers|-b) BRANCH_WORKERS="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$RUN_NAME" ]] && { echo "missing --run"  >&2; exit 2; }
[[ -z "$ARMS_RAW" ]] && { echo "missing --arms" >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IFS=',' read -ra ARMS <<< "$ARMS_RAW"

# Activate the venv that has programbench + scipy/numpy
# shellcheck disable=SC1091
source "$REPO/cache/pb-venv/bin/activate"

# We always go through harness/score-with-toolkit.py rather than
# `programbench eval` directly. The wrapper mounts our per-language deps
# volumes and the pb-all-langs-toolkit volume into every eval container,
# which is REQUIRED for the codex-lang-* arms to score correctly. The
# wrapper is resilient: volumes that don't exist on this host are silently
# skipped, so the same flow is safe for plain arms (vanilla, gstack-*, ...)
# on hosts that have never built the lang infra.
PB_EVAL=(python3 "$REPO/harness/score-with-toolkit.py" eval)

for arm in "${ARMS[@]}"; do
  arm_dir="$REPO/runs/$RUN_NAME/$arm"
  if [[ ! -d "$arm_dir" ]]; then
    echo "[score] skip: $arm_dir does not exist"
    continue
  fi
  echo "[score] === programbench eval $arm (workers=$WORKERS branch-workers=$BRANCH_WORKERS) ==="
  "${PB_EVAL[@]}" "$arm_dir" --workers "$WORKERS" --branch-workers "$BRANCH_WORKERS"
  echo
done

echo "[score] === harness/analyze.py ==="
"$REPO/harness/analyze.py" --run "$RUN_NAME" --arms "$ARMS_RAW"
