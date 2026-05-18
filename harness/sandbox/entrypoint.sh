#!/usr/bin/env bash
# Entrypoint for the agent container in sandbox mode.
#
# Required env vars (set by harness/run.sh):
#   PB_REPO              — bind-mounted repo root inside the container
#   PB_ARM               — arm name
#   PB_TASK              — task instance id
#   PB_RUN_NAME          — run label
#   PB_BUDGET            — max-budget-usd
#   PB_MODEL             — model id
#   PB_CLEANROOM         — name of the cleanroom container on the host
#   CLAUDE_CODE_OAUTH_TOKEN — auth token (subscription)
#   HTTPS_PROXY          — points at the whitelist proxy
#   HTTP_PROXY           — same

set -euo pipefail

# Claude Code refuses --permission-mode bypassPermissions as root. We start
# this entrypoint as root so we can fix /var/run/docker.sock perms (root-owned
# via Docker Desktop), then re-exec as node for the actual run. Drop privs
# BEFORE doing any per-run setup so RUN_CWD is owned by node.
if [[ "$(id -u)" -eq 0 ]]; then
  if [[ -S /var/run/docker.sock ]]; then
    chown root:node /var/run/docker.sock 2>/dev/null || true
    chmod 660 /var/run/docker.sock 2>/dev/null || true
  fi
  exec runuser -u node -- "$0" "$@"
fi

REPO="${PB_REPO:?PB_REPO must be set}"
ARM_DIR="$REPO/arms/${PB_ARM:?}"
TASK="${PB_TASK:?}"
RUN_NAME="${PB_RUN_NAME:?}"
BUDGET="${PB_BUDGET:?}"
MODEL="${PB_MODEL:?}"
CONTAINER="${PB_CLEANROOM:?}"

LOG_OUT="$REPO/logs/$RUN_NAME/$PB_ARM/$TASK"
RUN_CWD="$(mktemp -d -t pb-run-XXXX)"
mkdir -p "$LOG_OUT"

# --- Apply arm to run cwd ---
if [[ -d "$ARM_DIR/skills" ]]; then
  mkdir -p "$RUN_CWD/.claude/skills"
  cp -r "$ARM_DIR/skills/." "$RUN_CWD/.claude/skills/"
fi

SETTING_SOURCES=""
[[ -f "$ARM_DIR/setting-sources" ]] && SETTING_SOURCES="$(tr -d '\n' < "$ARM_DIR/setting-sources")"

# Render settings with absolute repo path (same as host runner).
RENDERED_SETTINGS="$RUN_CWD/.harness-settings.json"
sed "s|__PB_REPO__|$REPO|g" "$REPO/harness/settings-default.json" > "$RENDERED_SETTINGS"
if [[ -f "$ARM_DIR/settings.json" ]]; then
  python3 - "$RENDERED_SETTINGS" "$ARM_DIR/settings.json" <<'PY'
import json, sys
base = json.load(open(sys.argv[1]))
arm  = json.load(open(sys.argv[2]))
def merge(b, a):
    for k, v in a.items():
        if isinstance(v, dict) and isinstance(b.get(k), dict):
            merge(b[k], v)
        else:
            b[k] = v
merge(base, arm)
json.dump(base, open(sys.argv[1], "w"), indent=2)
PY
fi

if [[ -f "$ARM_DIR/mcp.json" ]]; then
  MCP_PATH="$ARM_DIR/mcp.json"
else
  MCP_PATH="$REPO/harness/mcp-empty.json"
fi

SYSTEM_PROMPT="$(cat "$REPO/harness/system.md")
$(cat "$ARM_DIR/orchestration.md")"

DISALLOWED_LINES="$(cat "$REPO/harness/disallowed-default")"
if [[ -f "$ARM_DIR/disallowed-extra" ]]; then
  DISALLOWED_LINES="$DISALLOWED_LINES
$(cat "$ARM_DIR/disallowed-extra")"
fi
DISALLOWED_FLAT="$(echo "$DISALLOWED_LINES" | sed '/^$/d' | tr '\n' ' ')"

TASK_PROMPT="The cleanroom container is running. Its name is in env var CLEANROOM (\"$CONTAINER\"). Begin by reading /workspace/README.md and any other docs, running ./executable --help, and surveying the binary. Then plan, implement, test, and produce /workspace/submission.tar.gz."

cd "$RUN_CWD"
echo "[entrypoint] launching claude -p in sandboxed agent (model=$MODEL budget=\$$BUDGET)"
CLEANROOM="$CONTAINER" claude -p \
  --setting-sources "$SETTING_SOURCES" \
  --strict-mcp-config --mcp-config "$MCP_PATH" \
  --settings "$RENDERED_SETTINGS" \
  --model "$MODEL" \
  --max-budget-usd "$BUDGET" \
  --no-session-persistence \
  --output-format stream-json \
  --include-partial-messages \
  --verbose \
  --append-system-prompt "$SYSTEM_PROMPT" \
  --disallowed-tools $DISALLOWED_FLAT \
  --permission-mode bypassPermissions \
  "$TASK_PROMPT" \
  > "$LOG_OUT/transcript.jsonl" 2> "$LOG_OUT/claude.stderr" \
  || echo "[entrypoint] claude exited non-zero: $?" >&2

echo "[entrypoint] done."
