#!/usr/bin/env bash
# Entrypoint for the Codex CLI agent container in sandbox mode.
#
# Parallel of entrypoint.sh, but invokes `codex exec` instead of `claude -p`.
#
# Required env vars (set by harness/run-codex.sh):
#   PB_REPO              — bind-mounted repo root inside the container
#   PB_ARM               — arm name
#   PB_TASK              — task instance id
#   PB_RUN_NAME          — run label
#   PB_BUDGET            — (informational only; Codex CLI has no built-in
#                          per-invocation USD budget. Captured for log
#                          parity with the Claude arm.)
#   PB_MODEL             — Codex model id (e.g. gpt-5.5)
#   PB_CLEANROOM         — name of the cleanroom container on the host
#   HTTPS_PROXY          — points at the whitelist proxy
#   HTTP_PROXY           — same
#   CODEX_HOME           — where Codex looks for auth.json + config.toml
#                          (set to /home/node/.codex in Dockerfile.codex)

set -euo pipefail

# Drop privileges to node (matching the Claude arm's pattern). Codex CLI
# does not refuse root the way Claude does, but we run as node so bind-mount
# ownership lines up and auth.json (mounted into /home/node/.codex) is
# readable by the running user.
if [[ "$(id -u)" -eq 0 ]]; then
  if [[ -S /var/run/docker.sock ]]; then
    chown root:node /var/run/docker.sock 2>/dev/null || true
    chmod 660 /var/run/docker.sock 2>/dev/null || true
  fi
  # Make sure /home/node/.codex is owned by node (auth.json is mounted as a
  # file, but Codex may try to create a session/log dir alongside it).
  mkdir -p /home/node/.codex
  chown -R node:node /home/node/.codex 2>/dev/null || true
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
# Codex CLI doesn't have a "skills" concept the way Claude Code does. If the
# arm ships a skills/ dir we still copy it for parity (an arm could reference
# the files in its orchestration.md), but there is no auto-loading.
if [[ -d "$ARM_DIR/skills" ]]; then
  mkdir -p "$RUN_CWD/.codex/skills"
  cp -r "$ARM_DIR/skills/." "$RUN_CWD/.codex/skills/"
fi

# Combine the harness system prompt and the arm's orchestration into a single
# "developer instructions" block. Codex CLI 0.130.0 has no
# --append-system-prompt equivalent for `exec`, so we prepend the system
# guidance to the user prompt. The two-section structure (SYSTEM /
# ORCHESTRATION / TASK) keeps the same content surface as the Claude arm.
SYSTEM_PROMPT="$(cat "$REPO/harness/system.md")
$(cat "$ARM_DIR/orchestration.md")"

TASK_PROMPT="The cleanroom container is running. Its name is in env var CLEANROOM (\"$CONTAINER\"). Begin by reading /workspace/README.md and any other docs, running ./executable --help, and surveying the binary. Then plan, implement, test, and produce /workspace/submission.tar.gz."

COMBINED_PROMPT="${SYSTEM_PROMPT}

---

# Current task

${TASK_PROMPT}"

cd "$RUN_CWD"
echo "[entrypoint-codex] launching codex exec in sandboxed agent (model=$MODEL budget=\$$BUDGET — informational only)"

# Notes on flags chosen:
#   exec                     — non-interactive mode (analog of `claude -p`).
#   --json                   — stream events as JSONL on stdout (transcript).
#   --skip-git-repo-check    — RUN_CWD is a fresh tmp dir, not a git repo.
#   --ephemeral              — don't write session state under $CODEX_HOME.
#                              Keeps the run hermetic.
#   --ignore-user-config     — do NOT read the host's bind-mounted
#                              config.toml. We want the CLI's built-in
#                              defaults (no model_reasoning_effort override,
#                              no fast_mode, no plugin/hook surface). Auth
#                              still uses $CODEX_HOME/auth.json.
#   --ignore-rules           — skip user/project execpolicy .rules files for
#                              the same reason.
#   --sandbox danger-full-access  — Codex's in-process sandbox would block
#                                  `docker exec` into the cleanroom; the
#                                  container is already the sandbox boundary.
#   --dangerously-bypass-approvals-and-sandbox — agent runs autonomously, no
#                                  prompts (analog of bypassPermissions).
#   -m "$MODEL"              — pin to the configured model.
#   NOTE: there is NO --max-budget-usd, NO --max-turns, NO disallowed-tools
#   surface for codex exec 0.130.0. The watchdog in run-codex.sh (timeout +
#   transcript-idle) is the only operational guardrail.
CLEANROOM="$CONTAINER" codex exec \
  --json \
  --skip-git-repo-check \
  --ephemeral \
  --ignore-user-config \
  --ignore-rules \
  --sandbox danger-full-access \
  --dangerously-bypass-approvals-and-sandbox \
  -m "$MODEL" \
  -o "$LOG_OUT/codex-last-message.txt" \
  "$COMBINED_PROMPT" \
  > "$LOG_OUT/transcript.jsonl" 2> "$LOG_OUT/codex.stderr" \
  || echo "[entrypoint-codex] codex exited non-zero: $?" >&2

echo "[entrypoint-codex] done."
