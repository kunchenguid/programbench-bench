#!/bin/bash
# Bake the de-pollution splice into the canonical codex-pilot-2 dataset.
#
# WHY: analyze.py reads runs/codex-pilot-2/ raw and is splice-UNAWARE, so a
# plain run reports the POLLUTED numbers (free 55.1) instead of the de-polluted
# ones (free 53.1). The de-pollution only lived in throwaway /tmp scripts. This
# permanently replaces each polluted (arm,task) cell in codex-pilot-2 with its
# clean strip-proto re-run, so analyze.py natively returns clean numbers.
#
# SAFETY: every file we overwrite is first copied to a dated backup tree
# (BACKUP_DIR) preserving arm/task structure, so the operation is fully
# reversible. Nothing is deleted; originals are preserved under backups/.
# Does NOT touch codex-lang-js's 14 currently-re-evaling tasks (the clean js
# cells are ffmpeg/jq/sqlite, which do not overlap).
set -euo pipefail
REPO="/Users/kunchen/github/kunchenguid/programbench-bench"
cd "$REPO"

SRC_RUNS="runs/strip-proto"
SRC_LOGS="logs/strip-proto"
DST_RUNS="runs/codex-pilot-2"
DST_LOGS="logs/codex-pilot-2"
BACKUP_DIR="backups/depollution-consolidation-20260608"

mkdir -p "$BACKUP_DIR/runs" "$BACKUP_DIR/logs"
echo "backup dir: $BACKUP_DIR"
echo

n=0
for arm in $(ls "$SRC_RUNS"); do
  for task in $(ls "$SRC_RUNS/$arm"); do
    src_cell="$SRC_RUNS/$arm/$task"
    dst_cell="$DST_RUNS/$arm/$task"
    [ -d "$dst_cell" ] || { echo "!! MISSING dst cell $dst_cell - skipping"; continue; }

    # ---- backup live (polluted) cell: eval.json + submission + transcript ----
    bkr="$BACKUP_DIR/runs/$arm/$task"; bkl="$BACKUP_DIR/logs/$arm/$task"
    mkdir -p "$bkr" "$bkl"
    cp -p "$dst_cell"/*.eval.json "$bkr"/ 2>/dev/null || true
    cp -p "$dst_cell"/submission.tar.gz "$bkr"/ 2>/dev/null || true
    cp -p "$DST_LOGS/$arm/$task/transcript.jsonl" "$bkl"/ 2>/dev/null || true

    # ---- overwrite live cell with clean strip-proto versions ----
    # remove stale eval.json(s) first so no polluted one lingers under a diff name
    rm -f "$dst_cell"/*.eval.json
    cp -p "$src_cell"/*.eval.json "$dst_cell"/
    cp -p "$src_cell"/submission.tar.gz "$dst_cell"/
    mkdir -p "$DST_LOGS/$arm/$task"
    cp -p "$SRC_LOGS/$arm/$task/transcript.jsonl" "$DST_LOGS/$arm/$task/" 2>/dev/null || \
      echo "   (no strip-proto transcript for $arm/$task - cost/turns keep old; backed up)"

    n=$((n+1))
    echo "  [$arm] $task  swapped (clean <- strip-proto)"
  done
done
echo
echo "consolidated $n cells."
echo
echo "=== verify: each arm still has 200 eval.json ==="
for arm in codex-free codex-lang-c codex-lang-go codex-lang-java codex-lang-js codex-lang-python codex-lang-ruby codex-lang-rust codex-lang-ts; do
  c=$(ls "$DST_RUNS/$arm"/*/*.eval.json 2>/dev/null | wc -l | tr -d ' ')
  echo "  $arm: $c"
done
echo
echo "=== backup inventory ==="
echo "  runs cells backed up: $(ls -d $BACKUP_DIR/runs/*/* 2>/dev/null | wc -l | tr -d ' ')"
echo "  eval.json backed up:  $(ls $BACKUP_DIR/runs/*/*/*.eval.json 2>/dev/null | wc -l | tr -d ' ')"
echo "  submissions backed up:$(ls $BACKUP_DIR/runs/*/*/submission.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
echo "  transcripts backed up:$(ls $BACKUP_DIR/logs/*/*/transcript.jsonl 2>/dev/null | wc -l | tr -d ' ')"
