#!/bin/bash
# Master post-batch eval orchestrator (2026-05-25 env-confound A+B finish).
# Serialized so eval workers never contend on the 15.6GiB Docker VM.
#   1. eval codex-vanilla-clean (196 tasks; jq + 3 disk-runaway pre-skipped)
#   2. re-eval the fixed mandated arms' false-zeros (reeval-fixed-arms.sh)
#   3. analyze.py across all 10 arms -> per-task.csv + summary
set -u
REPO="/Users/kunchen/github/kunchenguid/programbench-bench"
cd "$REPO"
PY="$REPO/cache/pb-venv/bin/python3"
export PB_DISK_EVICT_GB=160
LOG=/tmp/final-eval.log
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

say "########## FINAL EVAL START ##########"
say "=== STEP 1/3: eval codex-vanilla-clean (196 tasks, workers=2) ==="
"$PY" harness/score-with-toolkit.py eval runs/codex-pilot-1/codex-vanilla-clean \
  --workers 2 -b 2 >>"$LOG" 2>&1
say "vanilla-clean eval complete: $(find runs/codex-pilot-1/codex-vanilla-clean -name '*.eval.json' | wc -l | tr -d ' ')/200 eval.json"

say "=== STEP 2/3: re-eval fixed mandated arms ==="
bash harness/reeval-fixed-arms.sh >>"$LOG" 2>&1
say "fixed-arm re-eval complete"

say "=== STEP 3/3: analyze all 10 arms ==="
"$PY" harness/analyze.py --run codex-pilot-1 \
  --arms codex-vanilla,codex-vanilla-clean,codex-lang-c,codex-lang-go,codex-lang-java,codex-lang-js,codex-lang-python,codex-lang-ruby,codex-lang-rust,codex-lang-ts \
  >>"$LOG" 2>&1
say "########## FINAL EVAL DONE ##########"
