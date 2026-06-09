#!/bin/bash
# Supervisor for the claude-pilot-2 / claude-free baseline agent run.
# Keeps run-batch going until 200 valid (>=200B) submissions, auto-recovering
# from Claude 5-hr SESSION limits (which fast-fail agents into <200B sentinels,
# sometimes while keeping the run-batch driver alive). Recreated 2026-06-05 in
# the repo (the prior /tmp copy was wiped). Kun authorized auto-restart of the
# CLAUDE run. parallel=1 (Kun 2026-06-05) to minimize session-limit risk.
#
# Detection (incorporates the documented v2 fixes):
#   - SENTINEL BURST: >=3 sub-200B submissions written in the last 4 min =>
#     a rate-limit cascade (true whether the driver is alive or dead; at par=1
#     consecutive tasks fast-fail in seconds, so the burst still forms).
#   - DRIVER GONE + incomplete => relaunch (resume-skips valid); a no-progress
#     cap stops infinite thrash on a persistent (non-rate-limit) failure.
#   - pgrep WITHOUT -c (macOS pgrep has no -c).
#
# Launch:  nohup ./harness/claude-supervisor.sh > /tmp/claude-supervisor.out 2>&1 &
#          echo $! > /tmp/claude-supervisor.pid
# Stop:    kill $(cat /tmp/claude-supervisor.pid); pkill -f 'run-batch.sh --arms claude-free'
set -u
REPO="/Users/kunchen/github/kunchenguid/programbench-bench"; cd "$REPO"
ARM=claude-free; RUN=claude-pilot-2; PAR="${PAR:-1}"
BATCH_LOG=/tmp/claude-pilot-2-full.log
SLOG=/tmp/claude-supervisor.log
WAIT_SEC="${WAIT_SEC:-3600}"                 # session-reset wait
MAX_RL_CYCLES="${MAX_RL_CYCLES:-12}"         # cap rate-limit recovery cycles
MAX_NOPROG="${MAX_NOPROG:-3}"                # cap no-progress relaunches
say(){ echo "[$(date '+%m-%d %H:%M:%S')] $*" | tee -a "$SLOG"; }

valid(){ find runs/$RUN/$ARM/*/submission.tar.gz -size +199c 2>/dev/null | wc -l | tr -d ' '; }
agents(){ pgrep -f "run.sh --arm $ARM" 2>/dev/null | wc -l | tr -d ' '; }
driver(){ pgrep -f "run-batch.sh --arms $ARM" 2>/dev/null | wc -l | tr -d ' '; }
recent_sentinels(){ find runs/$RUN/$ARM/*/submission.tar.gz -size -200c -mmin -4 2>/dev/null | wc -l | tr -d ' '; }
launch(){ say "launch run-batch (parallel=$PAR, resume; valid=$(valid)/200)"; PB_PILOT2=1 nohup ./harness/run-batch.sh --arms "$ARM" --slice 0:200 --run-name "$RUN" --parallel "$PAR" >> "$BATCH_LOG" 2>&1 & echo $! > /tmp/claude-pilot-2-full.pid; }
stop_driver(){ local p; p=$(cat /tmp/claude-pilot-2-full.pid 2>/dev/null); [[ -n "$p" ]] && kill "$p" 2>/dev/null; pkill -f "run-batch.sh --arms $ARM" 2>/dev/null; sleep 2; }
drain(){ say "draining in-flight agents (count=$(agents))..."; while [[ "$(agents)" != 0 ]]; do sleep 30; done; say "drained."; }

say "########## CLAUDE SUPERVISOR START (arm=$ARM par=$PAR valid=$(valid)/200) ##########"
rl_cycles=0; noprog=0; last_valid=$(valid)
[[ "$(driver)" == 0 ]] && launch
while [[ "$(valid)" -lt 200 ]]; do
  sleep 120
  v=$(valid); rs=$(recent_sentinels); d=$(driver)
  if [[ "$rs" -ge 3 ]]; then
    say "RATE-LIMIT suspected: $rs sentinels in last 4min (valid=$v/200). stop+drain+wait ${WAIT_SEC}s."
    stop_driver; drain; sleep "$WAIT_SEC"
    rl_cycles=$((rl_cycles+1))
    [[ $rl_cycles -gt $MAX_RL_CYCLES ]] && { say "FATAL: >$MAX_RL_CYCLES rate-limit cycles; stopping for human."; exit 1; }
    launch
  elif [[ "$d" == 0 ]]; then
    if [[ "$v" -le "$last_valid" ]]; then noprog=$((noprog+1)); else noprog=0; fi
    [[ $noprog -ge $MAX_NOPROG ]] && { say "FATAL: $MAX_NOPROG relaunches with no progress (valid=$v/200); stopping for human."; exit 1; }
    say "driver gone at valid=$v/200; relaunch (resume) [noprog=$noprog]"
    drain; launch
  fi
  last_valid=$v
done
say "########## CLAUDE SUPERVISOR DONE: valid=$(valid)/200 ##########"
stop_driver
