#!/usr/bin/env bash
# Populate the pb-toolkit2 docker volume from pb/pilot2-toolkit:builder.
# Mounted read-only at /opt/tk2 in BOTH the codex-pilot-2 cleanroom (run-codex.sh
# PB_PILOT2=1) and the eval containers (score-with-toolkit.py). Ubuntu-22.04-native
# (node/ts, JDK17+maven, ruby3.1) - the four toolchains `:task` lacks.
set -euo pipefail
IMAGE=pb/pilot2-toolkit:builder
VOLUME=pb-toolkit2
REBUILD=0
[[ "${1:-}" == "--rebuild" ]] && REBUILD=1

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "error: $IMAGE not built. Run:" >&2
  echo "  docker build --platform linux/amd64 -t $IMAGE -f harness/sandbox/Dockerfile.pilot2-toolkit harness/sandbox" >&2
  exit 2; }

if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  if [[ "$REBUILD" -eq 1 ]]; then
    echo "[toolkit2] recreating volume"; docker volume rm "$VOLUME"; docker volume create "$VOLUME" >/dev/null
  else
    echo "[toolkit2] $VOLUME exists; pass --rebuild to recreate"; exit 0
  fi
else
  docker volume create "$VOLUME" >/dev/null
fi

docker run --rm --platform linux/amd64 -v "${VOLUME}:/dst" --entrypoint bash "$IMAGE" -euxc '
  cp -a /opt/tk2/. /dst/
  chmod -R a+rX /dst
  echo "--- toolkit2 layout ---"; du -sh /dst/*'
echo "[toolkit2] populated:"
docker run --rm -v "${VOLUME}:/d" --entrypoint sh alpine -c 'du -sh /d'
