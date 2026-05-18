#!/usr/bin/env bash
# Run one ProgramBench task with the OpenAI Codex CLI as the agent.
#
# Design parallel to harness/run.sh (the Claude Code runner). The two files
# duplicate scaffolding intentionally — option (a) from the proto plan — so
# that the Claude arm stays bit-for-bit untouched while the codex arm
# develops. Once the codex arm stabilizes we can consider folding both into
# a single dispatcher driven by arms/<arm>/image + arms/<arm>/entrypoint.
#
# Topology (same as run.sh):
#   pb-agent-net (--internal)   — agent has no external connectivity
#   pb-proxy-net                — proxy bridges agent-net and outside
#   cleanroom (--network none)  — separate, fully isolated
#   agent  -> HTTPS_PROXY=proxy:8888 -> proxy -> {api.openai.com,
#                                                chatgpt.com,
#                                                auth.openai.com,
#                                                ab.chatgpt.com}
#   agent  -> docker.sock (host) -> docker exec/cp into cleanroom
#
# Auth: requires a populated ~/.codex/auth.json on the host (run
# `codex login` once). The file is bind-mounted read-only into the agent
# container at $CODEX_HOME/auth.json (/home/node/.codex/auth.json).
#
# Usage: run-codex.sh --arm <name> --task <id> [--run-name N] [--budget USD]
#                     [--model M] [--keep-image] [--rebuild]

set -euo pipefail

ARM="" TASK=""
RUN_NAME="${PB_RUN_NAME:-default}"
BUDGET="${PB_BUDGET_USD:-50}"     # informational; codex has no built-in budget
MODEL="${PB_MODEL:-gpt-5.5}"
KEEP_IMAGE=0
REBUILD=0
TIMEOUT_SEC="${PB_TIMEOUT_SEC:-7200}"
IDLE_KILL_SEC="${PB_IDLE_KILL_SEC:-180}"
PRERESULT_IDLE_SEC="${PB_PRERESULT_IDLE_SEC:-900}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arm) ARM="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;;
    --run-name) RUN_NAME="$2"; shift 2 ;;
    --budget) BUDGET="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --keep-image) KEEP_IMAGE=1; shift 1 ;;
    --rebuild) REBUILD=1; shift 1 ;;
    --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
    --idle-kill) IDLE_KILL_SEC="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$ARM"  ]] && { echo "missing --arm"  >&2; exit 2; }
[[ -z "$TASK" ]] && { echo "missing --task" >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -d "$REPO/arms/$ARM" ]] || { echo "arm not found: $ARM" >&2; exit 2; }

CODEX_AUTH_HOST="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
[[ -f "$CODEX_AUTH_HOST" ]] || {
  echo "missing $CODEX_AUTH_HOST" >&2
  echo "Run 'codex login' on the host first." >&2
  exit 2
}

IMAGE="programbench/${TASK//__/_1776_}:task_cleanroom"
SUFFIX="${ARM}-${TASK//[^a-zA-Z0-9]/-}-$$"
CLEANROOM="pb-clean-$SUFFIX"
PROXY="pb-proxy-$SUFFIX"
AGENT="pb-agent-$SUFFIX"
NET_INTERNAL="pb-agent-net-$SUFFIX"
NET_BRIDGE="pb-proxy-net-$SUFFIX"

RUN_OUT="$REPO/runs/$RUN_NAME/$ARM/$TASK"
LOG_OUT="$REPO/logs/$RUN_NAME/$ARM/$TASK"
mkdir -p "$RUN_OUT" "$LOG_OUT"

cleanup() {
  set +e
  docker rm -f "$AGENT" "$PROXY" "$CLEANROOM" >/dev/null 2>&1
  docker network rm "$NET_INTERNAL" "$NET_BRIDGE" >/dev/null 2>&1
}
trap cleanup EXIT

echo "[sandbox-codex] task=$TASK arm=$ARM run=$RUN_NAME budget=\$$BUDGET keep_image=$KEEP_IMAGE model=$MODEL"

# --- Build images (cached) ---
if [[ "$REBUILD" -eq 1 ]] || ! docker image inspect pb/codex:latest >/dev/null 2>&1; then
  echo "[sandbox-codex] building pb/codex (this can take a minute)..."
  docker build --platform linux/amd64 -t pb/codex:latest -f "$REPO/harness/sandbox/Dockerfile.codex" "$REPO/harness/sandbox" \
    > "$LOG_OUT/build-codex.log" 2>&1
fi
if [[ "$REBUILD" -eq 1 ]] || ! docker image inspect pb/proxy:latest >/dev/null 2>&1; then
  echo "[sandbox-codex] building pb/proxy..."
  docker build --platform linux/amd64 -t pb/proxy:latest -f "$REPO/harness/sandbox/Dockerfile.proxy" "$REPO/harness/sandbox" \
    > "$LOG_OUT/build-proxy.log" 2>&1
fi

# --- Networks ---
docker network create --internal "$NET_INTERNAL" >/dev/null
docker network create "$NET_BRIDGE" >/dev/null

# --- Cleanroom ---
echo "[sandbox-codex] pulling cleanroom image $IMAGE"
docker pull --platform linux/amd64 "$IMAGE" >"$LOG_OUT/docker-pull.log" 2>&1
docker run -d --platform linux/amd64 \
  --name "$CLEANROOM" --network none --cpus 4 -w /workspace \
  "$IMAGE" sleep 8h >"$LOG_OUT/cleanroom.log" 2>&1

# --- Proxy ---
docker run -d --platform linux/amd64 \
  --name "$PROXY" --network "$NET_BRIDGE" \
  pb/proxy:latest >"$LOG_OUT/proxy.log" 2>&1
docker network connect "$NET_INTERNAL" "$PROXY" --alias proxy

# --- Agent ---
# Bind-mount the Codex auth.json read-only at the path Codex expects inside
# the container ($CODEX_HOME/auth.json = /home/node/.codex/auth.json).
TRANSCRIPT="$LOG_OUT/transcript.jsonl"
docker run -d --platform linux/amd64 \
  --name "$AGENT" --network "$NET_INTERNAL" \
  -v "$REPO":/pb \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$CODEX_AUTH_HOST":/home/node/.codex/auth.json:ro \
  -e PB_REPO=/pb \
  -e PB_ARM="$ARM" \
  -e PB_TASK="$TASK" \
  -e PB_RUN_NAME="$RUN_NAME" \
  -e PB_BUDGET="$BUDGET" \
  -e PB_MODEL="$MODEL" \
  -e PB_CLEANROOM="$CLEANROOM" \
  -e CODEX_HOME=/home/node/.codex \
  -e HTTPS_PROXY="http://proxy:8888" \
  -e HTTP_PROXY="http://proxy:8888" \
  -e NO_PROXY="" \
  pb/codex:latest \
  >/dev/null 2>&1

# Watchdog (identical semantics to run.sh): kill if timeout exceeded, or if
# transcript stops growing past idle threshold. Codex emits JSONL "events"
# rather than Claude's `type:"result"` events, so we don't probe for that
# specific marker — we rely on the size-growth signal alone, which is
# strictly weaker but still catches frozen-child cases.
START_TS=$(date +%s)
LAST_GROW_TS=$START_TS
LAST_SIZE=0
while docker inspect -f '{{.State.Running}}' "$AGENT" 2>/dev/null | grep -q true; do
  sleep 10
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))
  if (( ELAPSED >= TIMEOUT_SEC )); then
    echo "[sandbox-codex] timeout ${TIMEOUT_SEC}s reached; killing agent container" >&2
    docker rm -f "$AGENT" >/dev/null 2>&1 || true
    break
  fi
  if [[ -f "$TRANSCRIPT" ]]; then
    SIZE=$(wc -c <"$TRANSCRIPT" 2>/dev/null || echo 0)
    if (( SIZE > LAST_SIZE )); then
      LAST_SIZE=$SIZE
      LAST_GROW_TS=$NOW
    fi
    IDLE=$((NOW - LAST_GROW_TS))
    # Pre-result-vs-post-result distinction collapses here because we don't
    # parse codex JSONL events; use the larger of the two thresholds.
    if (( IDLE >= PRERESULT_IDLE_SEC )); then
      echo "[sandbox-codex] transcript idle ${IDLE}s; killing agent container" >&2
      docker rm -f "$AGENT" >/dev/null 2>&1 || true
      break
    fi
  fi
done
echo "[sandbox-codex] agent container terminated"

# --- Extract submission from cleanroom ---
if docker exec -u agent "$CLEANROOM" test -f /workspace/submission.tar.gz; then
  docker cp "$CLEANROOM:/workspace/submission.tar.gz" "$RUN_OUT/submission.tar.gz"
  echo "[sandbox-codex] submission saved: $RUN_OUT/submission.tar.gz ($(wc -c < "$RUN_OUT/submission.tar.gz") bytes)"
else
  echo "[sandbox-codex] WARNING: no submission.tar.gz produced" >&2
  tar czf "$RUN_OUT/submission.tar.gz" -T /dev/null
fi

# --- Image prune (cleanroom; agent/proxy images stay cached) ---
docker rm -f "$CLEANROOM" >/dev/null 2>&1 || true
if [[ "$KEEP_IMAGE" -eq 0 ]]; then
  echo "[sandbox-codex] pruning cleanroom image $IMAGE"
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
else
  echo "[sandbox-codex] keeping cleanroom image $IMAGE (--keep-image)"
fi

echo "[sandbox-codex] done."
