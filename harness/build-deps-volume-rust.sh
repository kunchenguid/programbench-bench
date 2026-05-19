#!/usr/bin/env bash
# Build the read-only docker volume of vendored crates mounted into the
# `codex-lang-rust` cleanroom at /opt/deps/rust.
#
# Strategy:
#   1. Fetch the top-N crates by all-time downloads from crates.io's
#      public API (no auth required).
#   2. Generate a synthetic Cargo.toml that depends on every one of them.
#   3. `cargo vendor` inside a throwaway pb/clean-lang-rust container with
#      network ON; this produces a vendor/ directory containing pinned
#      source for every crate + transitive deps.
#   4. Copy vendor/ into the named docker volume `pb-deps-rust` at
#      /opt/deps/rust/vendor (matching the path baked into the image's
#      cargo config). Write a manifest + sha256.
#
# Usage: harness/build-deps-volume-rust.sh [--top-n 100] [--rebuild]

set -euo pipefail

TOP_N=100
REBUILD=0
IMAGE=pb/clean-lang-rust:latest
VOLUME=pb-deps-rust

while [[ $# -gt 0 ]]; do
  case "$1" in
    --top-n) TOP_N="$2"; shift 2 ;;
    --rebuild) REBUILD=1; shift 1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "error: $IMAGE not built. Build it first." >&2
  exit 2
}

if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  if [[ "$REBUILD" -eq 1 ]]; then
    echo "[deps-rust] removing existing volume $VOLUME"
    docker volume rm "$VOLUME"
    docker volume create "$VOLUME" >/dev/null
  else
    echo "[deps-rust] $VOLUME already exists; pass --rebuild to recreate" >&2
    exit 0
  fi
else
  docker volume create "$VOLUME" >/dev/null
fi

SNAPSHOT_DATE="$(date -u +%Y-%m-%d)"
echo "[deps-rust] snapshot date $SNAPSHOT_DATE, top $TOP_N crates"

# Run cargo vendor inside a throwaway container with network ON. The
# baked-in cargo config sets net.offline=true and points crates.io at the
# vendor dir; we override both with env vars (CARGO_NET_OFFLINE=false) and
# a temporary config that points back at the real index.
docker run --rm --platform linux/amd64 \
  -v "${VOLUME}:/opt/deps/rust" \
  --env CARGO_NET_OFFLINE=false \
  --entrypoint bash \
  "$IMAGE" -euxc '
    apt-get update && apt-get install -y --no-install-recommends curl jq

    # Fetch top-N crates by all-time downloads from crates.io API.
    # The API caps per_page at 100, so a single page is enough for N<=100.
    PER_PAGE='"$TOP_N"'
    curl -fsSL -H "User-Agent: programbench-bench-deps-builder" \
      "https://crates.io/api/v1/crates?sort=downloads&per_page=${PER_PAGE}&page=1" \
      > /tmp/top.json
    jq -r ".crates[].id" /tmp/top.json > /tmp/crates.txt
    wc -l /tmp/crates.txt

    # Generate a synthetic Cargo.toml that depends on every crate at its
    # latest published version. `cargo vendor` will then download the full
    # transitive closure.
    mkdir -p /tmp/synth/src
    echo "fn main() {}" > /tmp/synth/src/main.rs
    {
      echo "[package]"
      echo "name = \"pb-deps-synth\""
      echo "version = \"0.0.1\""
      echo "edition = \"2021\""
      echo
      echo "[dependencies]"
      jq -r ".crates[] | \"\(.id) = \\\"\(.max_stable_version // .max_version)\\\"\"" /tmp/top.json
    } > /tmp/synth/Cargo.toml

    # Override the baked-in offline cargo config for THIS build.
    mkdir -p /tmp/synth/.cargo
    cat > /tmp/synth/.cargo/config.toml <<EOF
[net]
offline = false
EOF

    cd /tmp/synth
    # Some crates may fail to resolve together (semver conflicts); accept
    # partial vendoring rather than hard-fail. We log failures for review.
    if ! CARGO_HOME=/tmp/cargo-home cargo vendor --respect-source-config /opt/deps/rust/vendor 2> /opt/deps/rust/vendor-errors.log; then
      echo "[deps-rust] cargo vendor exited non-zero; check vendor-errors.log"
    fi

    # Manifest
    crate_count=$(ls /opt/deps/rust/vendor 2>/dev/null | wc -l)
    requested=$(wc -l < /tmp/crates.txt)
    {
      echo "{"
      echo "  \"snapshot_date\": \"'"$SNAPSHOT_DATE"'\","
      echo "  \"top_n_requested\": '"$TOP_N"',"
      echo "  \"crates_requested\": $(jq -R -s -c "split(\"\n\") | map(select(length > 0))" /tmp/crates.txt),"
      echo "  \"vendored_count\": $crate_count"
      echo "}"
    } > /opt/deps/rust/manifest.json
    sha256sum /opt/deps/rust/manifest.json | awk "{print \$1}" > /opt/deps/rust/snapshot-sha256
    echo "vendored $crate_count crates (requested $requested top-level)"
    cat /opt/deps/rust/snapshot-sha256
  '

echo "[deps-rust] done. snapshot sha256:"
docker run --rm -v "${VOLUME}:/opt/deps/rust" --entrypoint cat alpine /opt/deps/rust/snapshot-sha256
