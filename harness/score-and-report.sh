#!/usr/bin/env bash
# Run programbench eval on each arm of a run, then run the analyzer.
# Idempotent: programbench eval skips already-scored submissions.
#
# Usage: score-and-report.sh --run <name> --arms <a,b,...>

set -euo pipefail

RUN_NAME=""
ARMS_RAW=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN_NAME="$2"; shift 2 ;;
    --arms) ARMS_RAW="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
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

for arm in "${ARMS[@]}"; do
  arm_dir="$REPO/runs/$RUN_NAME/$arm"
  if [[ ! -d "$arm_dir" ]]; then
    echo "[score] skip: $arm_dir does not exist"
    continue
  fi
  echo "[score] === programbench eval $arm ==="
  programbench eval "$arm_dir"
  echo
done

echo "[score] === harness/analyze.py ==="
"$REPO/harness/analyze.py" --run "$RUN_NAME" --arms "$ARMS_RAW"
