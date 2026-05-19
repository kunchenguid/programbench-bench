#!/usr/bin/env bash
# Apply local patches to vendored programbench. Run after re-creating
# cache/pb-venv. Idempotent.
#
# Patches:
#   1. container.py: remove_image() retries on transient docker busy/lock
#      failures and logs warnings (stock silently swallows all errors,
#      letting compiled images leak).
#   2. eval/eval.py: in SingleEvaluator.run() finally block, also rmi the
#      base `programbench/<task>:<image_tag>` image (stock retains every
#      ~3 GB base it pulls; bloats disk on 200-task runs and crashes
#      eval with `no space left on device`).
#
# Implementation lives in _apply_patches.py so we can do exact text
# replacement against multi-line stock snippets without heredoc/shell
# escaping pain.

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PB="$REPO/cache/pb-venv/lib/python3.11/site-packages/programbench"

[[ -d "$PB" ]] || { echo "vendored programbench not found at $PB" >&2; exit 1; }
python3 "$REPO/harness/patches/_apply_patches.py" "$PB"
