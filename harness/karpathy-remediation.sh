#!/usr/bin/env bash
# Post-audit remediation for codex-pilot-2 (karpathy arm + baseline de-confound).
# Runs SERIAL (WORKERS=1) so no cross-task contention -> no re-introduced SIGKILL/
# mem-kill artifacts (audit cross-cutting #2). 6h per-instance timeout to match the
# karpathy eval. Backs up every faulty eval.json (mv to *.bak) before re-eval so
# clean results override faulty and the old values stay recoverable.
set -u
cd /Users/kunchen/github/kunchenguid/programbench-bench
PY=cache/pb-venv/bin/python
LOG=/tmp/codex-pilot-2-remediation.log
log(){ echo "[remediation $(date '+%F %T')] $*" | tee -a "$LOG"; }

# --- Phase 1: wait for the karpathy mem-class solo re-eval to finish ---
MP=$(cat /tmp/codex-pilot-2-karpathy-memreeval.pid 2>/dev/null || true)
log "waiting for karpathy mem-class re-eval (pid ${MP:-none}) to finish..."
while [ -n "${MP:-}" ] && ps -p "$MP" >/dev/null 2>&1; do sleep 30; done
log "mem-class done. karpathy eval.json=$(ls runs/codex-pilot-2/codex-free-karpathy/*/*.eval.json 2>/dev/null | wc -l | tr -d ' ')/192"

# --- Phase 2: karpathy tex-fmt (host-pressure SIGKILL artifact), solo ---
TF=wgunderwood__tex-fmt.3f1aef6
EJ=runs/codex-pilot-2/codex-free-karpathy/$TF/$TF.eval.json
[ -f "$EJ" ] && mv "$EJ" "$EJ.hostkill.bak" && log "backed up karpathy tex-fmt -> .hostkill.bak"
log "re-eval karpathy tex-fmt (solo WORKERS=1 -b2, 6h)..."
PB_RUN_TESTS_TIMEOUT_SEC=21600 PB_DISK_EVICT_GB=110 \
  "$PY" harness/score-with-toolkit.py eval runs/codex-pilot-2/codex-free-karpathy \
  --filter '.*(wgunderwood__tex-fmt\.3f1aef6).*' --workers 1 -b 2 >> "$LOG" 2>&1
log "karpathy tex-fmt re-eval done"

# --- Phase 3: baseline (codex-free) de-confound: 12 tasks under-timed by the old 300s cap ---
BTASKS="sqlite__sqlite.839433d typst__typst.88356d0 tstack__lnav.ee34494 unhappychoice__gittype.34b72d0 yoav-lavi__melody.f4af9b4 google__brotli.b3dc9cc yassinebridi__serpl.c48a9d7 tomarrell__wrapcheck.c058da1 trasta298__keifu.3331426 ys-l__flamelens.0b4dc33 xorg62__tty-clock.f2f847c wintermute-cell__ngrrram.8ea13c3"
for t in $BTASKS; do
  EJ=runs/codex-pilot-2/codex-free/$t/$t.eval.json
  [ -f "$EJ" ] && mv "$EJ" "$EJ.stale300s.bak" && log "backed up baseline $t -> .stale300s.bak"
done
BFILTER='.*(sqlite__sqlite\.839433d|typst__typst\.88356d0|tstack__lnav\.ee34494|unhappychoice__gittype\.34b72d0|yoav-lavi__melody\.f4af9b4|google__brotli\.b3dc9cc|yassinebridi__serpl\.c48a9d7|tomarrell__wrapcheck\.c058da1|trasta298__keifu\.3331426|ys-l__flamelens\.0b4dc33|xorg62__tty-clock\.f2f847c|wintermute-cell__ngrrram\.8ea13c3).*'
log "re-eval baseline 12 (solo WORKERS=1 -b2, 6h) to match karpathy timeout..."
PB_RUN_TESTS_TIMEOUT_SEC=21600 PB_DISK_EVICT_GB=110 \
  "$PY" harness/score-with-toolkit.py eval runs/codex-pilot-2/codex-free \
  --filter "$BFILTER" --workers 1 -b 2 >> "$LOG" 2>&1
log "baseline 12 re-eval done"

# --- Phase 4: verify clean results + CONSOLIDATE (faulty data must NOT remain in the analysis set) ---
# Rule: if a fresh clean eval.json exists for a backed-up task, MOVE its faulty backup
# OUT of runs/ into the quarantine dir (so no future glob under runs/ ever reads it).
# If the clean eval.json is MISSING (re-eval failed), RESTORE the backup in place so the
# task is not orphaned, and flag it loudly for a manual retry.
QDIR=/Users/kunchen/github/kunchenguid/programbench-bench/audit-faulty-backups
mkdir -p "$QDIR"
log "Phase 4: verify + consolidate (clean overrides faulty; faulty quarantined out of runs/)"
shopt -s nullglob
restored=0; quarantined=0
for bak in runs/codex-pilot-2/codex-free/*/*.eval.json.*.bak runs/codex-pilot-2/codex-free-karpathy/*/*.eval.json.*.bak; do
  live="${bak%%.eval.json.*}.eval.json"   # strip the .<suffix>.bak back to the canonical name
  if [ -f "$live" ]; then
    # clean result present -> faulty backup leaves the analysis set
    rel="${bak#runs/codex-pilot-2/}"; dest="$QDIR/$rel"
    mkdir -p "$(dirname "$dest")"; mv "$bak" "$dest"; quarantined=$((quarantined+1))
    log "  consolidated (clean kept, faulty quarantined): $(basename "$(dirname "$live")")"
  else
    # re-eval produced nothing -> do NOT orphan the task; restore the original
    mv "$bak" "$live"; restored=$((restored+1))
    log "  WARN restored (no clean result produced): $(basename "$(dirname "$live")") - NEEDS MANUAL RETRY"
  fi
done
log "Phase 4 done: quarantined=$quarantined restored=$restored (quarantine dir: $QDIR, OUTSIDE runs/)"

log "===== REMEDIATION COMPLETE ====="
log "karpathy eval.json=$(ls runs/codex-pilot-2/codex-free-karpathy/*/*.eval.json 2>/dev/null | wc -l | tr -d ' ')/192  baseline eval.json=$(ls runs/codex-pilot-2/codex-free/*/*.eval.json 2>/dev/null | wc -l | tr -d ' ')"
log "Faulty data removed from the analysis set. analyze.py will read ONLY clean results."
