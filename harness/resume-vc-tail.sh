#!/bin/bash
# Safe resume after the 2026-05-26 disk-runaway crash. Finishes the 24
# remaining codex-vanilla-clean tasks at --workers 1 with a REAL-TIME disk
# watchdog (not a 25-min poll), then STEP 2 (mandated re-evals) + STEP 3
# (analyze). The watchdog kills the running eval container + prunes the
# moment free disk dips below FLOOR_GB - long before the ~0-free wedge.
# A task whose container the watchdog kills records as a 0 (results_read_
# failed) naturally; no manual synth needed unless eval can't write a result.
set -u
REPO="/Users/kunchen/github/kunchenguid/programbench-bench"
cd "$REPO"
PY="$REPO/cache/pb-venv/bin/python3"
export PB_DISK_EVICT_GB=120     # evict base images when free<120GB (we have ~186); avoids unbounded image-cache growth without thrashing
export PB_RUN_TESTS_TIMEOUT_SEC=120  # hang/TUI/server tasks have MANY branches each hanging; 120s/branch fails them fast while branch-subsets of legit big suites still complete
FLOOR_GB=50                     # watchdog kill threshold (huge margin; no normal task uses tens of GB)
LOG=/tmp/vc-resume.log
WD_LOG=/tmp/vc-watchdog.log
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# ---- real-time disk watchdog (background) ----
WD_STOP=/tmp/vc-watchdog.stop
rm -f "$WD_STOP"
(
  while [ ! -f "$WD_STOP" ]; do
    free_gb=$(df -k / | tail -1 | awk '{print int($4/1048576)}')
    if [ "$free_gb" -lt "$FLOOR_GB" ]; then
      echo "[$(date +%H:%M:%S)] !! WATCHDOG TRIP: free=${free_gb}GB < ${FLOOR_GB}GB; killing eval containers + pruning" >> "$WD_LOG"
      docker ps --format '{{.Names}} {{.Status}}' >> "$WD_LOG" 2>&1
      docker rm -f $(docker ps -q) >/dev/null 2>&1
      docker image prune -f >/dev/null 2>&1
      echo "[$(date +%H:%M:%S)] watchdog: after prune free=$(df -k / | tail -1 | awk '{print int($4/1048576)}')GB" >> "$WD_LOG"
      sleep 8
    fi
    sleep 10
  done
) &
WD_PID=$!
say "watchdog armed (pid $WD_PID, floor ${FLOOR_GB}GB, log $WD_LOG)"

say "########## RESUME START ##########"
# programbench eval re-evaluates EVERY task in the dir (it does NOT skip
# already-scored), so scope it to ONLY the tasks still missing eval.json
# via a full-match --filter regex (dots escaped). Otherwise it would waste
# hours re-evaling the 176 done tasks and re-hit the runaway.
missing=()
for d in runs/codex-pilot-1/codex-vanilla-clean/*/; do
  t=$(basename "$d"); [ -f "$d/$t.eval.json" ] || missing+=("$t")
done
say "=== STEP 1/3: finish codex-vanilla-clean (${#missing[@]} remaining, workers=1) ==="
if [ ${#missing[@]} -gt 0 ]; then
  esc=$(printf '%s\n' "${missing[@]}" | sed 's/\./\\./g' | paste -sd'|' -)
  FILTER="(${esc})"
  say "filter: $FILTER"
  # workers 1 = one task at a time (bounds disk-runaway blast radius to one task);
  # -b 3 = run that task's branches 3-at-a-time (huge speedup for many-branch hang
  # tasks); --branch-retries 0 = don't re-run a timed-out branch (it'll just hang
  # again). Watchdog handles the faster fill from -b 3.
  "$PY" harness/score-with-toolkit.py eval runs/codex-pilot-1/codex-vanilla-clean \
    --filter "$FILTER" --workers 1 -b 3 --branch-retries 0 >>"$LOG" 2>&1
fi
say "vanilla-clean eval done: $(find runs/codex-pilot-1/codex-vanilla-clean -name '*.eval.json' | wc -l | tr -d ' ')/200"

# synth-skip any task that STILL has no eval.json (watchdog-killed runaway that
# couldn't write a result) so the denominator stays 200.
say "=== synth-skip any task with no eval.json (confirmed un-evaluatable) ==="
"$PY" - <<'PY' | tee -a "$LOG"
import json,os
from programbench.eval.eval import EvaluationResult
base="runs/codex-pilot-1/codex-vanilla-clean"
note="SYNTHETIC compile_failed (2026-05-26 safe-resume): task un-evaluatable (disk-runaway killed by watchdog); scored 0 to keep n=200."
for t in sorted(os.listdir(base)):
    d=os.path.join(base,t)
    if not os.path.isdir(d): continue
    ev=os.path.join(d,f"{t}.eval.json")
    if os.path.exists(ev): continue
    tmpl=None
    import glob
    for c in glob.glob(f"runs/codex-pilot-1/*/{t}/{t}.eval.json"):
        tmpl=c; break
    if not tmpl:
        print(f"  WARN no template for {t}; skipping"); continue
    j=json.load(open(tmpl)); j["test_results"]=[]; j["error_code"]="compile_failed"; j["error_details"]=note; j["executable_hash"]=None
    json.dump(j, open(ev,"w"), indent=2)
    EvaluationResult.model_validate_json(open(ev).read())
    print(f"  SYNTH-SKIP {t}")
PY

say "=== STEP 2/3: re-eval fixed mandated arms ==="
bash harness/reeval-fixed-arms.sh >>"$LOG" 2>&1
say "fixed-arm re-eval done"

say "=== STEP 3/3: analyze all 10 arms ==="
"$PY" harness/analyze.py --run codex-pilot-1 \
  --arms codex-vanilla,codex-vanilla-clean,codex-lang-c,codex-lang-go,codex-lang-java,codex-lang-js,codex-lang-python,codex-lang-ruby,codex-lang-rust,codex-lang-ts \
  >>"$LOG" 2>&1

touch "$WD_STOP"; kill "$WD_PID" 2>/dev/null
say "########## RESUME DONE ##########"
