#!/usr/bin/env bash
# Make the codex-pilot-2 FULL run exactly 200 tasks by pre-excluding the
# testorg__calculator scaffold fixture BEFORE slicing, in BOTH run-batch.sh and
# the stripe orchestrator (so --slice indices stay aligned between them).
#
# Idempotent (marker-guarded). Self-verifying (bash -n). Fails safe: if an
# anchor is missing it leaves the file untouched and exits non-zero.
#
# DO NOT run while a stripe/batch is live - editing a script bash is executing
# corrupts the running process. Intended to run AFTER the pilot completes,
# before launching the full run.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARK="# PB_200_FIX"
rc=0

patch_file() {  # file  anchor  insert_after(1)/before(0)  block
  local f="$1" anchor="$2" after="$3" block="$4"
  if grep -qF "$MARK" "$f"; then echo "[skip] $f already has $MARK"; return 0; fi
  if ! grep -qF "$anchor" "$f"; then echo "[ERROR] anchor not found in $f" >&2; rc=1; return 1; fi
  python3 - "$f" "$anchor" "$after" "$block" <<'PY'
import sys
f, anchor, after, block = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
src = open(f).read()
if after == "1":
    src = src.replace(anchor, anchor + block, 1)
else:
    src = src.replace(anchor, block + anchor, 1)
open(f, "w").write(src)
PY
  echo "[ok]   patched $f"
}

# 1. run-batch.sh: drop EXCLUDED_TASKS from ALL_TASKS right after it is built,
#    so the subsequent --slice/--filter/all selectors index the 200-real-task list.
RB="$REPO/harness/run-batch.sh"
RB_ANCHOR='while IFS= read -r line; do ALL_TASKS+=("$line"); done < <(ls "$TASKS_DIR" | sort)
'
RB_BLOCK='# PB_200_FIX: pre-exclude fixtures BEFORE slicing so --slice indexes the real-task
# list (codex-pilot-2 wants exactly 200, not 201 incl. the testorg scaffold).
_pb200=(); for _t in "${ALL_TASKS[@]}"; do is_excluded "$_t" || _pb200+=("$_t"); done
ALL_TASKS=("${_pb200[@]}")
'
patch_file "$RB" "$RB_ANCHOR" 1 "$RB_BLOCK"

# 2. run-stripe-pipeline.sh: drop the same fixture(s) from TASKS before the cap,
#    so TOTAL is the real 200 (10x20 stripes) and indices align with run-batch.
SP="$REPO/harness/run-stripe-pipeline.sh"
SP_ANCHOR='# PB_MAX_TASKS caps the run'
SP_BLOCK='# PB_200_FIX: drop fixture tasks (match run-batch.sh EXCLUDED_TASKS) so TOTAL is 200.
_pbexcl=(testorg__calculator.abc1234); _pbkeep=()
for _t in "${TASKS[@]}"; do _sk=0; for _x in "${_pbexcl[@]}"; do [[ "$_t" == "$_x" ]] && _sk=1; done; (( _sk )) || _pbkeep+=("$_t"); done
TASKS=("${_pbkeep[@]}")
'
patch_file "$SP" "$SP_ANCHOR" 0 "$SP_BLOCK"

# Verify syntax of anything we touched.
for f in "$RB" "$SP"; do bash -n "$f" || { echo "[ERROR] bash -n failed for $f" >&2; rc=1; }; done
(( rc == 0 )) && echo "[apply-200-fix] OK" || echo "[apply-200-fix] FAILED (rc=$rc)"
exit $rc
