#!/usr/bin/env bash
# Build the read-only docker volume of installed gems for the
# `codex-lang-ruby` cleanroom at /opt/deps/ruby/installed.
#
# Strategy: rubygems.org has download stats but no public top-N API
# without auth, so we use a curated list of widely-used gems. Install
# each into /opt/deps/ruby/installed (which is exported via GEM_PATH in
# the image). `gem fetch` also populates /opt/deps/ruby/cache with raw
# .gem files for any agent that wants to install additional gems
# (those would need network, which the cleanroom doesn't have, but
# `gem install --local /opt/deps/ruby/cache/<gem>.gem` works).

set -euo pipefail

REBUILD=0
IMAGE=pb/clean-lang-ruby:latest
VOLUME=pb-deps-ruby

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift 1 ;;
    --top-n)   shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "error: $IMAGE not built" >&2; exit 2; }
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  if [[ "$REBUILD" -eq 1 ]]; then docker volume rm "$VOLUME"; docker volume create "$VOLUME" >/dev/null
  else echo "[deps-ruby] $VOLUME exists; pass --rebuild to recreate"; exit 0; fi
else docker volume create "$VOLUME" >/dev/null; fi

SNAPSHOT_DATE="$(date -u +%Y-%m-%d)"

docker run --rm --platform linux/amd64 \
  -v "${VOLUME}:/opt/deps/ruby" \
  --entrypoint bash \
  "$IMAGE" -euxc '
    mkdir -p /opt/deps/ruby/installed /opt/deps/ruby/cache

    cat > /tmp/gems.txt <<EOF
rake
bundler
rspec
minitest
test-unit
nokogiri
json
yaml
csv
ostruct
thor
optparse
slop
gli
commander
rainbow
pastel
tty-prompt
tty-progressbar
tty-table
tty-spinner
tty-screen
tty-cursor
colorize
paint
http
httparty
faraday
rest-client
typhoeus
excon
sinatra
sinatra-contrib
rack
puma
unicorn
sequel
activesupport
activerecord
activemodel
activejob
mail
pry
pry-byebug
byebug
awesome_print
hashie
multi_json
oj
sass
redis
dalli
EOF

    while read gem; do
      [ -z "$gem" ] && continue
      gem install --no-document --install-dir /opt/deps/ruby/installed "$gem" 2>>/opt/deps/ruby/install-errors.log || echo "[warn] gem install $gem failed"
    done < /tmp/gems.txt

    chmod -R a+rX /opt/deps/ruby
    gem_count=$(find /opt/deps/ruby/installed/gems -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    {
      echo "{"
      echo "  \"snapshot_date\": \"'"$SNAPSHOT_DATE"'\","
      echo "  \"gems_requested\": $(jq -R -s -c "split(\"\n\") | map(select(length > 0))" /tmp/gems.txt 2>/dev/null || echo "null"),"
      echo "  \"installed_count\": $gem_count"
      echo "}"
    } > /opt/deps/ruby/manifest.json
    sha256sum /opt/deps/ruby/manifest.json | awk "{print \$1}" > /opt/deps/ruby/snapshot-sha256
    echo "[deps-ruby] $gem_count installed gem dirs"
    cat /opt/deps/ruby/snapshot-sha256
  '
echo "[deps-ruby] done"
