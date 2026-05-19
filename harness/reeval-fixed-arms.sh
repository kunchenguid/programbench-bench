#!/bin/bash
# Re-eval the false-zero tasks of the mandated arms after the 2026-05-25
# env-confound A fixes (C dev headers, ruby libyaml, python venv+cp310
# wheels), plus eval the new codex-vanilla-clean arm. Runs sequentially
# (one arm at a time) so eval workers don't contend on the 15.6GiB VM.
#
# Per fixed mandated arm: re-inject the current prelude into the
# false-zero submissions, delete their eval.json, re-eval (skips the
# already-good ones). Go/Rust OOM tasks re-eval at --workers 1.
#
# Idempotent. Logs to /tmp/reeval-fixed.log.
set -u
REPO="/Users/kunchen/github/kunchenguid/programbench-bench"
cd "$REPO"
PY="$REPO/cache/pb-venv/bin/python3"
export PB_DISK_EVICT_GB=160
LOG=/tmp/reeval-fixed.log
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# tasks (dir names) of an arm whose current eval is a false-zero candidate.
# crit: compile_failed, or pct==0, or (interpreted) pct<thresh.
targets(){ # arm thresh
  local arm="$1" thresh="$2"
  "$PY" - "$arm" "$thresh" <<'PY'
import json,os,sys
arm,thresh=sys.argv[1],float(sys.argv[2])
base=f"runs/codex-pilot-1/{arm}"
for t in sorted(os.listdir(base)):
    d=os.path.join(base,t)
    if not os.path.isdir(d): continue
    ev=os.path.join(d,f"{t}.eval.json")
    if not os.path.exists(ev): continue
    try: j=json.load(open(ev))
    except: continue
    tr=j.get("test_results",[]); n=len(tr)
    p=sum(1 for x in tr if x.get("status")=="passed")
    pct=100*p/n if n else 0
    if j.get("error_code")=="compile_failed" or pct<thresh:
        print(t)
PY
}

reeval_arm(){ # arm thresh workers reinject(0/1)
  local arm="$1" thresh="$2" workers="$3" reinj="$4"
  mapfile -t TS < <(targets "$arm" "$thresh")
  say "=== $arm: ${#TS[@]} false-zero targets (thresh<$thresh, workers=$workers, reinject=$reinj) ==="
  [ ${#TS[@]} -eq 0 ] && { say "  none"; return; }
  if [ "$reinj" = "1" ]; then
    "$PY" harness/reinject-prelude.py "$arm" "${TS[@]}" >>"$LOG" 2>&1
  fi
  local filt; filt=$(printf '%s|' "${TS[@]}"); filt="(${filt%|})"
  for t in "${TS[@]}"; do rm -f "runs/codex-pilot-1/$arm/$t/$t.eval.json"; done
  say "  re-evaluating $arm ..."
  "$PY" harness/score-with-toolkit.py eval "runs/codex-pilot-1/$arm" \
    --filter "${filt}" --workers "$workers" -b 2 >>"$LOG" 2>&1
  say "  $arm done."
}

say "########## RE-EVAL FIXED ARMS START ##########"
# C / python: compile_failed driven (thresh 0.01 catches only true zeros + compile_failed)
reeval_arm codex-lang-c      0.01 2 1
reeval_arm codex-lang-python 0.01 2 1
# ruby: yaml/gem crashes show as very low pct (~0-2%); reinject libyaml + re-eval <5
reeval_arm codex-lang-ruby   5    2 1
# go/rust OOM compiles: no prelude change; re-eval the compile_failed/zero at workers=1
reeval_arm codex-lang-go     0.01 1 0
reeval_arm codex-lang-rust   0.01 1 0
say "########## RE-EVAL FIXED ARMS DONE ##########"
