#!/usr/bin/env bash
# Stripe-mode pipeline orchestrator for the per-language-evaluation experiment.
#
# Why stripes: a multi-arm pipeline that processes "all tasks of arm 1, then
# all tasks of arm 2, ..." re-pulls every task image once per arm. With our
# disk budget that means we can't keep images cached between arms, so each
# arm starts cold and exhausts Docker Hub's rate limit (we got 429s during
# codex-pilot-1's JS arm and TS scoring after the unauthenticated 100/6hr
# anon limit). Stripe mode processes a small batch of N tasks through ALL
# arms (agents + eval) before moving to the next batch, so each task image
# is pulled exactly once and disk peak per stripe stays bounded.
#
# Per stripe of N tasks:
#   1. Run agents for each arm on stripe (resume-skips already-done).
#   2. Delete any *.eval.json that contains a RuntimeError (rate-limit
#      false-zero from prior runs). programbench eval skips already-scored
#      submissions, so this is what makes those eligible for re-eval.
#   3. Run eval for each arm on stripe (programbench eval --slice).
#   4. Prune docker images for stripe's tasks (cleanroom + task tags).
#
# At end: emit final report via harness/analyze.py across all 9 arms.
#
# Tunables:
#   STRIPE_SIZE              (default 10)
#   PB_DISK_EVICT_GB         (env var, default 100 in this script) -
#                            demand-based eviction inside programbench eval
#                            triggers below this much free disk; an extra
#                            safety net beneath the stripe-end prune.
#   RUN_NAME                 (default codex-pilot-1)
#
# This script is idempotent: re-running picks up where it stopped because
# every step uses resume-skip / already-scored semantics.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_NAME="${RUN_NAME:-codex-pilot-1}"
STRIPE_SIZE="${STRIPE_SIZE:-20}"
PARALLEL="${PARALLEL:-4}"
WORKERS="${WORKERS:-4}"
BRANCH_WORKERS="${BRANCH_WORKERS:-2}"
BRANCH_RETRIES="${BRANCH_RETRIES:-1}"   # retries on a results_read_failed branch; set 0 to skip futile retries of hang/broken tasks

export PB_DISK_EVICT_GB="${PB_DISK_EVICT_GB:-160}"

# codex-pilot-2: set PB_PILOT2=1 (cleanroom == :task eval image) - propagated to
# run-batch.sh -> run-codex.sh and inert for the eval (score-with-toolkit mounts
# pb-toolkit2 unconditionally). Default 0 keeps the pilot-1 topology.
export PB_PILOT2="${PB_PILOT2:-0}"

# Arms: override with PB_ARMS="a,b,c". DEFAULT = every arm directory already
# present under runs/$RUN_NAME/ - so a RESUME can never silently drop an arm by a
# forgotten PB_ARMS. (Regression guard: the 2026-05-30 codex-pilot-2 resume omitted
# PB_ARMS and the old hardcoded 8-arm default dropped codex-free for 4 stripes.)
# A brand-new run has no run dir yet, so it MUST pass PB_ARMS explicitly.
if [[ -n "${PB_ARMS:-}" ]]; then
  IFS=',' read -ra ARMS <<< "$PB_ARMS"
else
  ARMS=()
  if [[ -d "$REPO/runs/$RUN_NAME" ]]; then
    mapfile -t ARMS < <(find "$REPO/runs/$RUN_NAME" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
  fi
  if [[ ${#ARMS[@]} -eq 0 ]]; then
    echo "error: PB_ARMS unset and no arm dirs under runs/$RUN_NAME - a fresh run MUST pass PB_ARMS=a,b,c" >&2
    exit 2
  fi
  echo "[stripe] PB_ARMS unset; defaulting to arms discovered in runs/$RUN_NAME: ${ARMS[*]}" >&2
fi
# Analyze baseline arm (first in the pair comparisons). pilot-1: codex-vanilla;
# pilot-2: codex-free. Defaults to the first arm if unset.
BASELINE_ARM="${PB_BASELINE:-${ARMS[0]}}"
# Tasks to skip at EVAL (disk-runaway / broken). Comma list; default the known set.
IFS=',' read -ra BLOCKLIST <<< "${PB_BLOCKLIST:-tinycc__tinycc.9b8765d,stathissideris__ditaa.f2286c4,tarka__xcp.5e5b448,alecthomas__chroma.8d04def}"
is_blocklisted() { local t="$1" x; for x in "${BLOCKLIST[@]}"; do [[ "$t" == "$x" ]] && return 0; done; return 1; }

PYBIN="$REPO/cache/pb-venv/bin/python3"
SCORE_SCRIPT="$REPO/harness/score-with-toolkit.py"

LOG_DIR="$REPO/logs/$RUN_NAME/_stripe"
mkdir -p "$LOG_DIR"
MAIN_LOG="$LOG_DIR/main.log"

log() {
  echo "[stripe $(date '+%H:%M:%S')] $*" | tee -a "$MAIN_LOG"
}

# Task list comes from the existing TS arm directory (200 tasks, the same
# slice run-batch.sh uses). This MUST match the sort order run-batch.sh
# applies internally; lexicographic on instance id matches both.
# Task universe must match run-batch.sh's --slice ordering EXACTLY: the full
# programbench data/tasks dir, `ls | sort`. (run-batch slices this list, then
# drops EXCLUDED_TASKS post-slice, so we keep the scaffold here for index
# parity.) For a fresh run there is no run dir to read, so derive from the data
# dir directly; this is the canonical source.
DATA_TASKS_DIR="$REPO/cache/pb-venv/lib/python3.11/site-packages/programbench/data/tasks"
if [[ -d "$DATA_TASKS_DIR" ]]; then
  mapfile -t TASKS < <(ls "$DATA_TASKS_DIR" | sort)
elif [[ -d "$REPO/runs/$RUN_NAME/${ARMS[0]}" ]]; then
  mapfile -t TASKS < <(ls "$REPO/runs/$RUN_NAME/${ARMS[0]}" | sort)
else
  echo "error: cannot find programbench data tasks dir or a seeded run dir" >&2
  exit 2
fi
# PB_200_FIX: drop fixture tasks (match run-batch.sh EXCLUDED_TASKS) so TOTAL is 200.
_pbexcl=(testorg__calculator.abc1234); _pbkeep=()
for _t in "${TASKS[@]}"; do _sk=0; for _x in "${_pbexcl[@]}"; do [[ "$_t" == "$_x" ]] && _sk=1; done; (( _sk )) || _pbkeep+=("$_t"); done
TASKS=("${_pbkeep[@]}")
# PB_MAX_TASKS caps the run to the first N tasks (for a bounded PILOT). Unset =
# full task set. The cap applies to the canonical sorted list, so the pilot's N
# tasks are a stable prefix and the later full run is a superset.
if [[ -n "${PB_MAX_TASKS:-}" ]] && (( PB_MAX_TASKS < ${#TASKS[@]} )); then
  TASKS=("${TASKS[@]:0:$PB_MAX_TASKS}")
fi
TOTAL="${#TASKS[@]}"
log "task list: $TOTAL tasks${PB_MAX_TASKS:+ (capped by PB_MAX_TASKS=$PB_MAX_TASKS)}; stripe size $STRIPE_SIZE -> $(( (TOTAL + STRIPE_SIZE - 1) / STRIPE_SIZE )) stripes"
log "arms: ${ARMS[*]}"
log "PB_PILOT2=$PB_PILOT2  baseline=$BASELINE_ARM"
log "disk evict threshold: ${PB_DISK_EVICT_GB} GB"
log "blocklist (operationally enforced via disk-watchdog.sh + short PB_RUN_TESTS_TIMEOUT_SEC): ${BLOCKLIST[*]}"

free_gib() {
  df -k / | tail -1 | awk '{printf "%.1f", $4 / 1048576}'
}

prune_task_images() {
  local task="$1"
  # Task ids look like "abishekvashok__cmatrix.5c082c6"; programbench
  # mangles them to "abishekvashok_1776_cmatrix.5c082c6" for the pulled
  # base/cleanroom images but keeps `__` for the locally-committed
  # `programbench-compiled/<task>:<uuid>` images (see eval.py:865). At
  # stripe-end every arm has finished its eval for this task, so both
  # namespaces are safe to drop -- they're regenerated on the next run.
  local safe="${task//__/_1776_}"
  local ids
  ids="$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null \
    | awk -v base="programbench/${safe}" -v comp="programbench-compiled/${task}" \
        '$1 ~ "^"base":" || $1 ~ "^"comp":" {print $2}' \
    | sort -u)"
  if [[ -n "$ids" ]]; then
    echo "$ids" | xargs docker rmi -f >/dev/null 2>&1 || true
  fi
}

for (( start=0; start<TOTAL; start+=STRIPE_SIZE )); do
  end=$(( start + STRIPE_SIZE ))
  (( end > TOTAL )) && end=$TOTAL
  # PB_START_TASK (default 0): skip stripes whose task range is entirely below
  # this index. Use on a resume to jump past already-fully-complete stripes
  # WITHOUT re-walking their hang-task evals (the eval step re-runs broken/
  # incomplete branches every resume - see AGENTS.md). MUST be a multiple of
  # STRIPE_SIZE and every task [0:PB_START_TASK] must be fully evaluated, or you
  # silently drop real work. 2026-05-28: set 80 to resume at stripe 4 after a
  # WORKERS=2 relaunch (stripes 0-3 confirmed complete, all arms eval>=80).
  if (( start < ${PB_START_TASK:-0} )); then
    log "skip stripe [$start:$end] (PB_START_TASK=${PB_START_TASK:-0}; already complete, not re-walking)"
    continue
  fi
  stripe_log="$LOG_DIR/stripe-$(printf '%03d' "$start").log"
  log "===== STRIPE [$start:$end] of $TOTAL ====="
  log "stripe log: $stripe_log"

  # 1-3 interleaved: arm N+1 agents run in parallel with arm N eval.
  # Agents are I/O-bound (LLM API), eval is CPU-bound (pytest-xdist), so they
  # share the host without thrashing. The pattern per stripe is:
  #   arm 1 agents [fg] → arm 1 clean+eval [bg] || arm 2 agents [fg]
  #                                              → arm 2 clean+eval [bg] || arm 3 agents [fg]
  #                                              → ...
  #                                              → arm 8 clean+eval [bg]
  # At end-of-stripe we wait on all background evals before pruning, so
  # eviction of stripe's images doesn't race a still-running eval.
  eval_pids=()
  for arm in "${ARMS[@]}"; do
    log "agent: $arm [$start:$end]"
    "$REPO/harness/run-batch.sh" \
      --arms "$arm" \
      --slice "$start:$end" \
      --run-name "$RUN_NAME" \
      --parallel "$PARALLEL" \
      >>"$stripe_log" 2>&1
    rc=$?
    if (( rc != 0 )); then
      log "  WARN: $arm agents exited rc=$rc (continuing)"
    fi

    # Clean false-zero (RuntimeError) eval.json for this arm's stripe tasks
    # immediately before launching its eval so re-eval is eligible.
    arm_cleaned=0
    for (( i=start; i<end; i++ )); do
      task="${TASKS[$i]}"
      f="$REPO/runs/$RUN_NAME/$arm/$task/$task.eval.json"
      if [[ -f "$f" ]] && grep -q "RuntimeError" "$f" 2>/dev/null; then
        rm -f "$f"
        arm_cleaned=$(( arm_cleaned + 1 ))
      fi
    done
    (( arm_cleaned > 0 )) && log "  cleaned $arm_cleaned RuntimeError eval.json for $arm"

    arm_run="$REPO/runs/$RUN_NAME/$arm"
    if [[ -d "$arm_run" ]]; then
      # 1-eval concurrency cap (2026-05-27): wait on the previous arm's eval
      # before launching this one, so at most ONE background eval runs at a
      # time -> total eval workers = WORKERS (4), not WORKERS x (number of
      # arms whose eval is still running). Keeps eval||next-arm-agents overlap
      # but stops evals from stacking and oversubscribing the host.
      if (( ${#eval_pids[@]} > 0 )); then
        last_eval_pid="${eval_pids[${#eval_pids[@]}-1]}"   # portable last-element (bash 3.2 has no [-1])
        log "  1-eval cap: waiting on prior eval (pid $last_eval_pid) before $arm"
        wait "$last_eval_pid" || log "  prior eval pid $last_eval_pid exited non-zero (continuing)"
      fi
      log "eval (bg): $arm [$start:$end]"
      "$PYBIN" "$SCORE_SCRIPT" eval \
        --slice "$start:$end" \
        --workers "$WORKERS" \
        -b "$BRANCH_WORKERS" \
        --branch-retries "$BRANCH_RETRIES" \
        "$arm_run" \
        >>"$stripe_log" 2>&1 &
      eval_pids+=("$!")
    else
      log "  skip eval $arm: no run dir"
    fi
  done

  # Wait for all background evals to complete before pruning. Their images
  # may still be in use; we must let them finish first or the prune races.
  log "waiting on ${#eval_pids[@]} background eval processes..."
  for pid in "${eval_pids[@]}"; do
    wait "$pid" || log "  eval pid $pid exited non-zero (continuing)"
  done
  log "all evals complete"

  # 4. Prune stripe's images.
  pre_prune_gib="$(free_gib)"
  pruned=0
  for (( i=start; i<end; i++ )); do
    prune_task_images "${TASKS[$i]}"
    pruned=$(( pruned + 1 ))
  done
  post_prune_gib="$(free_gib)"
  delta_gib="$(awk -v a="$post_prune_gib" -v b="$pre_prune_gib" 'BEGIN{printf "%.1f", a-b}')"
  log "pruned $pruned task image sets. free disk: ${pre_prune_gib} -> ${post_prune_gib} GiB (+${delta_gib})"
  # Sanity warn if delta is suspiciously small (probable leak)
  if awk "BEGIN{exit !($delta_gib < 5)}"; then
    log "  WARN: stripe prune freed only ${delta_gib} GiB; check for compiled-image or snapshot leaks"
  fi
done

log "===== ALL STRIPES DONE ====="
log "running final analyze across all 9 arms..."

# Baseline arm first (its pair comparisons drive the report). If BASELINE_ARM is
# already in ARMS, don't duplicate it.
analyze_arms="$BASELINE_ARM"
for a in "${ARMS[@]}"; do [[ "$a" == "$BASELINE_ARM" ]] || analyze_arms+=",$a"; done
"$PYBIN" "$REPO/harness/analyze.py" \
  --run "$RUN_NAME" \
  --arms "$analyze_arms" \
  >>"$MAIN_LOG" 2>&1
log "analyze rc=$?"
log "done."
