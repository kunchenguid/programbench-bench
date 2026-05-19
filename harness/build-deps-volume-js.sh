#!/usr/bin/env bash
# Build the read-only docker volume of npm packages mounted into the
# `codex-lang-js` cleanroom at /opt/deps/js.
#
# Strategy: hardcoded list of widely-used npm packages (curated since
# the npmjs registry API doesn't expose download rankings cleanly).
# `npm install` each into a throwaway project with --cache pointing at
# the deps volume. The cache is content-addressed and supports
# `npm install --offline` at agent runtime.

set -euo pipefail

REBUILD=0
IMAGE=pb/clean-lang-js:latest
VOLUME=pb-deps-js

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift 1 ;;
    --top-n)   shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "error: $IMAGE not built" >&2; exit 2; }
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  if [[ "$REBUILD" -eq 1 ]]; then docker volume rm "$VOLUME"; docker volume create "$VOLUME" >/dev/null
  else echo "[deps-js] $VOLUME exists; pass --rebuild to recreate"; exit 0; fi
else docker volume create "$VOLUME" >/dev/null; fi

SNAPSHOT_DATE="$(date -u +%Y-%m-%d)"

docker run --rm --platform linux/amd64 \
  -v "${VOLUME}:/opt/deps/js" \
  --env NPM_CONFIG_OFFLINE=false \
  --env NPM_CONFIG_CACHE=/opt/deps/js/cache \
  --entrypoint bash \
  "$IMAGE" -euxc '
    mkdir -p /opt/deps/js/cache /tmp/synth
    cd /tmp/synth
    npm init -y >/dev/null

    cat > /tmp/packages.txt <<EOF
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
helmet
morgan
dotenv
nodemon
mocha
chai
jest
sinon
supertest
eslint
prettier
typescript
ts-node
@types/node
uuid
moment
date-fns
luxon
ramda
rxjs
async
bluebird
ws
socket.io
http-proxy
proxy-agent
inquirer
ora
boxen
figlet
cli-table3
chalk-table
log-symbols
listr2
enquirer
prompts
cosmiconfig
yaml
js-yaml
ini
toml
jsonwebtoken
bcrypt
crypto-js
node-forge
sharp
pino
winston
EOF

    # Install into a throwaway prefix so the global node_modules is not
    # touched; the important side effect is the populated npm cache.
    while read pkg; do
      [ -z "$pkg" ] && continue
      npm install --prefix /tmp/synth --no-save --no-audit --no-fund "$pkg" 2>>/opt/deps/js/install-errors.log || echo "[warn] npm install $pkg failed"
    done < /tmp/packages.txt

    chmod -R a+rX /opt/deps/js

    cache_count=$(find /opt/deps/js/cache -name "*.tgz" 2>/dev/null | wc -l)
    {
      echo "{"
      echo "  \"snapshot_date\": \"'"$SNAPSHOT_DATE"'\","
      echo "  \"packages_requested\": $(jq -R -s -c "split(\"\n\") | map(select(length > 0))" /tmp/packages.txt 2>/dev/null || echo "null"),"
      echo "  \"cache_tarball_count\": $cache_count"
      echo "}"
    } > /opt/deps/js/manifest.json
    sha256sum /opt/deps/js/manifest.json | awk "{print \$1}" > /opt/deps/js/snapshot-sha256
    echo "[deps-js] $cache_count cached tarballs; manifest sha:"
    cat /opt/deps/js/snapshot-sha256
  '
echo "[deps-js] done"
