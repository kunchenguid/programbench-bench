#!/usr/bin/env bash
# Run one ProgramBench task with the agent in a network-sandboxed container.
#
# Topology:
#   pb-agent-net (--internal)   — agent has no external connectivity
#   pb-proxy-net                — proxy bridges agent-net and outside
#   cleanroom (--network none)  — separate, fully isolated
#   agent  -> HTTPS_PROXY=proxy:8888 -> proxy -> api.anthropic.com only
#   agent  -> docker.sock (host) -> docker exec/cp into cleanroom
#
# Auth: requires CLAUDE_CODE_OAUTH_TOKEN. Generate once on the host with
# `claude setup-token` and save it to .claude-oauth-token (gitignored).
#
# Usage: run.sh --arm <name> --task <id> [--run-name N] [--budget USD]
#                [--model M] [--keep-image] [--rebuild]

set -euo pipefail

ARM="" TASK=""
RUN_NAME="${PB_RUN_NAME:-default}"
BUDGET="${PB_BUDGET_USD:-50}"
MODEL="${PB_MODEL:-claude-opus-4-7}"
KEEP_IMAGE=0
REBUILD=0
TIMEOUT_SEC="${PB_TIMEOUT_SEC:-7200}"
IDLE_KILL_SEC="${PB_IDLE_KILL_SEC:-180}"        # idle after a result event lands
PRERESULT_IDLE_SEC="${PB_PRERESULT_IDLE_SEC:-900}"   # idle without any result event (frozen mid-tool-use)
AUTO_COMPACT_WINDOW="${PB_AUTO_COMPACT_WINDOW:-400000}"   # claude -p auto-compacts when context hits this many tokens (cap, not %)

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
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$ARM"  ]] && { echo "missing --arm"  >&2; exit 2; }
[[ -z "$TASK" ]] && { echo "missing --task" >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -d "$REPO/arms/$ARM" ]] || { echo "arm not found: $ARM" >&2; exit 2; }

TOKEN_FILE="$REPO/.claude-oauth-token"
[[ -f "$TOKEN_FILE" ]] || {
  echo "missing $TOKEN_FILE" >&2
  echo "Run 'claude setup-token' on the host, copy the token, and save to that file." >&2
  exit 2
}
OAUTH_TOKEN="$(tr -d '\n\r ' < "$TOKEN_FILE")"
[[ -n "$OAUTH_TOKEN" ]] || { echo "$TOKEN_FILE is empty" >&2; exit 2; }

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

echo "[sandbox] task=$TASK arm=$ARM run=$RUN_NAME budget=\$$BUDGET keep_image=$KEEP_IMAGE"

# --- Build images (cached) ---
if [[ "$REBUILD" -eq 1 ]] || ! docker image inspect pb/agent:latest >/dev/null 2>&1; then
  echo "[sandbox] building pb/agent (this can take a minute)..."
  docker build --platform linux/amd64 -t pb/agent:latest -f "$REPO/harness/sandbox/Dockerfile.agent" "$REPO/harness/sandbox" \
    > "$LOG_OUT/build-agent.log" 2>&1
fi
if [[ "$REBUILD" -eq 1 ]] || ! docker image inspect pb/proxy:latest >/dev/null 2>&1; then
  echo "[sandbox] building pb/proxy..."
  docker build --platform linux/amd64 -t pb/proxy:latest -f "$REPO/harness/sandbox/Dockerfile.proxy" "$REPO/harness/sandbox" \
    > "$LOG_OUT/build-proxy.log" 2>&1
fi

# --- Networks ---
docker network create --internal "$NET_INTERNAL" >/dev/null
docker network create "$NET_BRIDGE" >/dev/null

# --- Cleanroom (isolated, the agent does NOT share its network) ---
echo "[sandbox] pulling cleanroom image $IMAGE"
docker pull --platform linux/amd64 "$IMAGE" >"$LOG_OUT/docker-pull.log" 2>&1
docker run -d --platform linux/amd64 \
  --name "$CLEANROOM" --network none --cpus 4 -w /workspace \
  "$IMAGE" sleep 8h >"$LOG_OUT/cleanroom.log" 2>&1

# --- Proxy (on bridge for outbound + on internal for the agent) ---
docker run -d --platform linux/amd64 \
  --name "$PROXY" --network "$NET_BRIDGE" \
  pb/proxy:latest >"$LOG_OUT/proxy.log" 2>&1
docker network connect "$NET_INTERNAL" "$PROXY" --alias proxy

# --- Agent (only on internal net; no DNS resolution outside CONNECT proxy) ---
# Mount repo at /pb (Dockerfile WORKDIR + ENTRYPOINT path). Writable so the
# entrypoint can land transcripts/submissions in runs/ and logs/.
TRANSCRIPT="$LOG_OUT/transcript.jsonl"
docker run -d --platform linux/amd64 \
  --name "$AGENT" --network "$NET_INTERNAL" \
  -v "$REPO":/pb \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e PB_REPO=/pb \
  -e PB_ARM="$ARM" \
  -e PB_TASK="$TASK" \
  -e PB_RUN_NAME="$RUN_NAME" \
  -e PB_BUDGET="$BUDGET" \
  -e PB_MODEL="$MODEL" \
  -e PB_CLEANROOM="$CLEANROOM" \
  -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH_TOKEN" \
  -e CLAUDE_CODE_AUTO_COMPACT_WINDOW="$AUTO_COMPACT_WINDOW" \
  -e HTTPS_PROXY="http://proxy:8888" \
  -e HTTP_PROXY="http://proxy:8888" \
  -e NO_PROXY="" \
  -e OPENCLAW_SESSION=1 \
  pb/agent:latest \
  >/dev/null 2>&1

# Watchdog: kill the agent container after TIMEOUT_SEC absolute, OR after
# IDLE_KILL_SEC since last transcript write (claude -p occasionally hangs on
# orphan child shells after emitting result; this is the failure mode that
# silently burned hours during early runs).
START_TS=$(date +%s)
LAST_GROW_TS=$START_TS
LAST_SIZE=0
while docker inspect -f '{{.State.Running}}' "$AGENT" 2>/dev/null | grep -q true; do
  sleep 10
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))
  if (( ELAPSED >= TIMEOUT_SEC )); then
    echo "[sandbox] timeout ${TIMEOUT_SEC}s reached; killing agent container" >&2
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
    if (( IDLE >= IDLE_KILL_SEC )) && grep -q '"type":"result"' "$TRANSCRIPT" 2>/dev/null; then
      echo "[sandbox] transcript idle ${IDLE}s after result event; killing agent container" >&2
      docker rm -f "$AGENT" >/dev/null 2>&1 || true
      break
    fi
    if (( IDLE >= PRERESULT_IDLE_SEC )) && ! grep -q '"type":"result"' "$TRANSCRIPT" 2>/dev/null; then
      echo "[sandbox] transcript idle ${IDLE}s with no result event; killing agent container" >&2
      docker rm -f "$AGENT" >/dev/null 2>&1 || true
      break
    fi
  fi
done
echo "[sandbox] agent container terminated"

# --- Extract submission from cleanroom ---
if docker exec -u agent "$CLEANROOM" test -f /workspace/submission.tar.gz; then
  docker cp "$CLEANROOM:/workspace/submission.tar.gz" "$RUN_OUT/submission.tar.gz"
  echo "[sandbox] submission saved: $RUN_OUT/submission.tar.gz ($(wc -c < "$RUN_OUT/submission.tar.gz") bytes)"
else
  echo "[sandbox] WARNING: no submission.tar.gz produced" >&2
  tar czf "$RUN_OUT/submission.tar.gz" -T /dev/null
fi

# --- Image prune (cleanroom; agent/proxy images stay cached) ---
docker rm -f "$CLEANROOM" >/dev/null 2>&1 || true
if [[ "$KEEP_IMAGE" -eq 0 ]]; then
  echo "[sandbox] pruning cleanroom image $IMAGE"
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
else
  echo "[sandbox] keeping cleanroom image $IMAGE (--keep-image)"
fi

echo "[sandbox] done."
