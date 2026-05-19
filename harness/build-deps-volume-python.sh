#!/usr/bin/env bash
# Build the read-only docker volume of pip wheels mounted into the
# `codex-lang-python` cleanroom at /opt/deps/python.
#
# Strategy:
#   1. Pick the top-N PyPI packages by 30-day download count from the
#      canonical hugovk/top-pypi-packages dataset (https://hugovk.github.io
#      /top-pypi-packages/). Snapshot date is recorded in the manifest.
#   2. Spin up a throwaway pb/clean-lang-python container with network ON
#      (this script runs on the host; the cleanroom at run time is still
#      --network none).
#   3. `pip download` each package + its transitive deps into a wheelhouse
#      directory inside a named docker volume `pb-deps-python`.
#   4. Write a manifest (snapshot date, package list, wheel count, sha256
#      of the manifest itself) into the volume so the run name can pin to
#      a reproducible snapshot.
#
# Usage: harness/build-deps-volume-python.sh [--top-n 100] [--rebuild]
#
# Output: docker volume `pb-deps-python` populated at /python/wheels with
# .whl files and /python/manifest.json describing the snapshot.

set -euo pipefail

TOP_N=100
REBUILD=0
IMAGE=pb/clean-lang-python:latest
VOLUME=pb-deps-python

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top-n) TOP_N="$2"; shift 2 ;;
    --rebuild) REBUILD=1; shift 1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "error: $IMAGE not built. Run:" >&2
  echo "  docker build --platform linux/amd64 -t $IMAGE -f harness/sandbox/Dockerfile.clean-lang-python harness/sandbox" >&2
  exit 2
}

if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  if [[ "$REBUILD" -eq 1 ]]; then
    echo "[deps-python] removing existing volume $VOLUME"
    docker volume rm "$VOLUME"
    docker volume create "$VOLUME" >/dev/null
  else
    echo "[deps-python] $VOLUME already exists; pass --rebuild to recreate" >&2
    exit 0
  fi
else
  docker volume create "$VOLUME" >/dev/null
fi

SNAPSHOT_DATE="$(date -u +%Y-%m-%d)"
echo "[deps-python] snapshot date $SNAPSHOT_DATE, top $TOP_N packages"

# Run pip download inside a throwaway container with network ON. PIP_NO_INDEX
# baked into the image is cleared with `--env PIP_NO_INDEX=` so pip actually
# talks to PyPI for this build step.
docker run --rm --platform linux/amd64 \
  -v "${VOLUME}:/opt/deps/python" \
  --env PIP_NO_INDEX= \
  --env PIP_FIND_LINKS= \
  --env PIP_DISABLE_PIP_VERSION_CHECK=1 \
  --entrypoint bash \
  "$IMAGE" -euxc '
    mkdir -p /opt/deps/python/wheels
    cd /tmp

    # Fetch the top-N list from hugovk/top-pypi-packages (canonical
    # snapshot dataset). Pull the 30-day list.
    apt-get update && apt-get install -y --no-install-recommends curl
    curl -fsSL https://hugovk.github.io/top-pypi-packages/top-pypi-packages.min.json -o top.json
    python3 -c "
import json, sys
data = json.load(open(\"top.json\"))
rows = data[\"rows\"][:'"$TOP_N"']
for r in rows:
    print(r[\"project\"])
" > packages.txt

    # Some top packages do not publish wheels and would need a build
    # toolchain (which we deliberately do NOT include in this image).
    # `pip download` will skip them only if --only-binary=:all: is set.
    # We try --only-binary first, then fall back to a permissive pass.
    pip download --no-cache-dir --dest /opt/deps/python/wheels --only-binary=:all: \
        --platform manylinux2014_x86_64 --python-version 3.11 --implementation cp --abi cp311 \
        -r packages.txt 2> /opt/deps/python/download-errors.log || true

    # Second pass: try to fetch source dists for anything that did not
    # resolve as a wheel. These will still be installable as long as
    # pip can build them at agent runtime (which requires the agent has
    # a build toolchain - python3-dev IS in the image).
    pip download --no-cache-dir --dest /opt/deps/python/wheels \
        -r packages.txt 2>> /opt/deps/python/download-errors.log || true

    # Manifest
    python3 -c "
import hashlib, json, os
wheels = sorted(os.listdir(\"/opt/deps/python/wheels\"))
pkgs = [l.strip() for l in open(\"packages.txt\") if l.strip()]
manifest = {
    \"snapshot_date\": \"'"$SNAPSHOT_DATE"'\",
    \"top_n_requested\": '"$TOP_N"',
    \"packages_requested\": pkgs,
    \"wheel_count\": len(wheels),
    \"wheels\": wheels,
}
data = json.dumps(manifest, indent=2, sort_keys=True).encode()
sha = hashlib.sha256(data).hexdigest()
open(\"/opt/deps/python/manifest.json\", \"wb\").write(data)
open(\"/opt/deps/python/snapshot-sha256\", \"w\").write(sha + \"\n\")
print(\"snapshot sha256:\", sha)
print(\"wheel count:\", len(wheels))
"
  '

echo "[deps-python] done. snapshot sha256:"
docker run --rm -v "${VOLUME}:/opt/deps/python" --entrypoint cat alpine /opt/deps/python/snapshot-sha256
