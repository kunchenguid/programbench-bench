#!/usr/bin/env bash
# Build the read-only docker volume of npm packages for the
# `codex-lang-ts` cleanroom. Mirror of build-deps-volume-js.sh but extends
# the curated list with typescript-essential packages (@types/* and
# common TS tooling).

set -euo pipefail

REBUILD=0
IMAGE=pb/clean-lang-ts:latest
VOLUME=pb-deps-ts

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift 1 ;;
    --top-n)   shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "error: $IMAGE not built" >&2; exit 2; }
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  if [[ "$REBUILD" -eq 1 ]]; then docker volume rm "$VOLUME"; docker volume create "$VOLUME" >/dev/null
  else echo "[deps-ts] $VOLUME exists; pass --rebuild to recreate"; exit 0; fi
else docker volume create "$VOLUME" >/dev/null; fi

SNAPSHOT_DATE="$(date -u +%Y-%m-%d)"

docker run --rm --platform linux/amd64 \
  -v "${VOLUME}:/opt/deps/ts" \
  --env NPM_CONFIG_OFFLINE=false \
  --env NPM_CONFIG_CACHE=/opt/deps/ts/cache \
  --entrypoint bash \
  "$IMAGE" -euxc '
    mkdir -p /opt/deps/ts/cache /tmp/synth
    cd /tmp/synth
    npm init -y >/dev/null

    # JS top-50 union with TS essentials.
    cat > /tmp/packages.txt <<EOF
typescript
ts-node
tsx
@types/node
@types/express
@types/lodash
@types/yargs
@types/minimist
@types/glob
@types/fs-extra
@types/uuid
@types/jest
@types/mocha
@types/chai
@types/jsonwebtoken
@types/bcrypt
@types/ws
@types/koa
zod
io-ts
class-validator
class-transformer
reflect-metadata
tslib
type-fest
lodash
chalk
commander
yargs
minimist
glob
fs-extra
debug
axios
node-fetch
express
koa
fastify
body-parser
cors
dotenv
mocha
chai
jest
ts-jest
sinon
supertest
eslint
prettier
uuid
date-fns
ramda
rxjs
ws
inquirer
ora
boxen
yaml
js-yaml
jsonwebtoken
bcrypt
pino
winston
EOF

    while read pkg; do
      [ -z "$pkg" ] && continue
      npm install --prefix /tmp/synth --no-save --no-audit --no-fund "$pkg" 2>>/opt/deps/ts/install-errors.log || echo "[warn] npm install $pkg failed"
    done < /tmp/packages.txt

    chmod -R a+rX /opt/deps/ts
    cache_count=$(find /opt/deps/ts/cache -name "*.tgz" 2>/dev/null | wc -l)
    {
      echo "{"
      echo "  \"snapshot_date\": \"'"$SNAPSHOT_DATE"'\","
      echo "  \"packages_requested\": $(jq -R -s -c "split(\"\n\") | map(select(length > 0))" /tmp/packages.txt 2>/dev/null || echo "null"),"
      echo "  \"cache_tarball_count\": $cache_count"
      echo "}"
    } > /opt/deps/ts/manifest.json
    sha256sum /opt/deps/ts/manifest.json | awk "{print \$1}" > /opt/deps/ts/snapshot-sha256
    echo "[deps-ts] $cache_count cached tarballs"
    cat /opt/deps/ts/snapshot-sha256
  '
echo "[deps-ts] done"
