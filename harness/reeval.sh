#!/bin/bash
# Durable re-eval entry point: re-score one arm's EXISTING submissions at a given
# per-branch test timeout, skipping the structurally-broken tasks.
#
# NO agent re-run ($0 API): the eval resume-skips fully-complete instances and
# only re-runs the timed-out / not_run branches, now under the given ceiling.
# Replaces the old one-off wrappers (reeval-6hr.sh / reeval-js-clean.sh /
# score-tdd-6hr.sh), which each hand-copied the blocklist. The skip-list here is
# single-sourced from analyze.py's REPORT_BLOCKLIST, so it can never drift.
#
# Everything else it relies on already lives in the durable core:
#   - per-branch timeout + per-task hang caps: harness/patches/_apply_patches.py
#     (PB_RUN_TESTS_TIMEOUT_SEC is the global default the map overrides)
#   - demand-based disk eviction: PB_DISK_EVICT_GB (same patch file)
#   - report-time blocklist: analyze.py REPORT_BLOCKLIST (the source we read here)
# Pair with harness/disk-watchdog.sh + harness/mem-watchdog.sh for large evals.
#
# Usage: harness/reeval.sh <arm> [timeout_sec=21600] [run_name=codex-pilot-2]
#   harness/reeval.sh codex-lang-js                # re-score JS at 6h
#   harness/reeval.sh codex-free-tdd 1800          # de-pollution-cell headroom
#   WORKERS=2 BRANCH_WORKERS=4 harness/reeval.sh codex-lang-c
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
PY="$REPO/cache/pb-venv/bin/python"

ARM="${1:?usage: reeval.sh <arm> [timeout_sec] [run_name]}"
TIMEOUT="${2:-21600}"
RUN="${3:-codex-pilot-2}"

export PB_RUN_TESTS_TIMEOUT_SEC="$TIMEOUT"
export PB_DISK_EVICT_GB="${PB_DISK_EVICT_GB:-80}"
WORKERS="${WORKERS:-2}"
BRANCH_WORKERS="${BRANCH_WORKERS:-4}"

# Single source of truth: build the eval skip-filter from analyze.REPORT_BLOCKLIST
# (full-match negative-lookahead on the repo name, anchored anywhere in the id).
FILTER="$("$PY" - <<'PYEOF'
import sys, re
sys.path.insert(0, "harness")
from analyze import REPORT_BLOCKLIST
print("(?!.*(" + "|".join(re.escape(t) for t in sorted(REPORT_BLOCKLIST)) + ")).*")
PYEOF
)"
[ -n "$FILTER" ] || { echo "[reeval] FATAL: could not build skip-filter from analyze.REPORT_BLOCKLIST" >&2; exit 1; }

echo "[reeval] arm=$ARM run=$RUN timeout=${TIMEOUT}s evict=${PB_DISK_EVICT_GB}G workers=$WORKERS b=$BRANCH_WORKERS"
echo "[reeval] skip-filter (from analyze.REPORT_BLOCKLIST): $FILTER"

"$PY" harness/score-with-toolkit.py eval "runs/$RUN/$ARM" \
  --filter "$FILTER" --workers "$WORKERS" -b "$BRANCH_WORKERS"

ev=$(ls "runs/$RUN/$ARM"/*/*.eval.json 2>/dev/null | wc -l | tr -d ' ')
echo "[reeval] $ARM done: $ev eval.json present under runs/$RUN/$ARM"
