#!/usr/bin/env bash
# Build the read-only docker volume of Go modules mounted into the
# `codex-lang-go` cleanroom at /opt/deps/go.
#
# Strategy: pkg.go.dev does not publish download rankings via API, so we
# use a curated list of widely-used Go modules (web frameworks, CLI libs,
# logging, testing, AWS, cloud-native, observability). Pull the latest
# version of each via `go get` into a synthetic module, then snapshot the
# GOMODCACHE into the volume. The list is in the script for repro.

set -euo pipefail

REBUILD=0
IMAGE=pb/clean-lang-go:latest
VOLUME=pb-deps-go

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift 1 ;;
    --top-n)   shift 2 ;;  # accepted for consistency; ignored (curated)
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "error: $IMAGE not built" >&2; exit 2; }
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  if [[ "$REBUILD" -eq 1 ]]; then docker volume rm "$VOLUME"; docker volume create "$VOLUME" >/dev/null
  else echo "[deps-go] $VOLUME exists; pass --rebuild to recreate"; exit 0; fi
else docker volume create "$VOLUME" >/dev/null; fi

SNAPSHOT_DATE="$(date -u +%Y-%m-%d)"

docker run --rm --platform linux/amd64 \
  -v "${VOLUME}:/opt/deps/go" \
  --env GOPROXY=https://proxy.golang.org,direct \
  --env GOFLAGS= \
  --entrypoint bash \
  "$IMAGE" -euxc '
    mkdir -p /opt/deps/go/pkg/mod /tmp/synth
    cd /tmp/synth
    go mod init pb-deps-synth

    # Curated top Go modules (rough ordering by Github stars / usage).
    cat > /tmp/modules.txt <<EOF
github.com/spf13/cobra
github.com/spf13/viper
github.com/spf13/pflag
github.com/stretchr/testify
github.com/sirupsen/logrus
github.com/gin-gonic/gin
github.com/labstack/echo/v4
github.com/gorilla/mux
github.com/gorilla/websocket
github.com/pkg/errors
github.com/google/uuid
github.com/google/go-cmp
github.com/google/go-github/v60
github.com/golang/protobuf
github.com/golang-jwt/jwt/v5
github.com/go-sql-driver/mysql
github.com/lib/pq
github.com/mattn/go-sqlite3
github.com/jackc/pgx/v5
github.com/prometheus/client_golang
github.com/prometheus/common
github.com/hashicorp/go-multierror
github.com/hashicorp/go-version
github.com/hashicorp/golang-lru/v2
github.com/hashicorp/go-hclog
github.com/mitchellh/mapstructure
github.com/mitchellh/go-homedir
github.com/fatih/color
github.com/fatih/structs
github.com/dustin/go-humanize
github.com/cheggaaa/pb/v3
github.com/schollz/progressbar/v3
github.com/charmbracelet/bubbletea
github.com/charmbracelet/lipgloss
github.com/charmbracelet/bubbles
github.com/rivo/tview
github.com/gdamore/tcell/v2
github.com/mattn/go-isatty
github.com/mattn/go-runewidth
github.com/olekukonko/tablewriter
github.com/jedib0t/go-pretty/v6
github.com/spf13/afero
github.com/spf13/jwalterweatherman
github.com/spf13/cast
github.com/sourcegraph/conc
github.com/davecgh/go-spew
github.com/pmezard/go-difflib
github.com/yuin/goldmark
github.com/microcosm-cc/bluemonday
github.com/PuerkitoBio/goquery
golang.org/x/text
golang.org/x/net
golang.org/x/sys
golang.org/x/crypto
golang.org/x/sync
golang.org/x/term
golang.org/x/exp
golang.org/x/tools
golang.org/x/oauth2
golang.org/x/time
gopkg.in/yaml.v3
gopkg.in/yaml.v2
gopkg.in/ini.v1
EOF

    while read mod; do
      [ -z "$mod" ] && continue
      go get "$mod" || echo "[warn] go get $mod failed"
    done < /tmp/modules.txt

    # GOMODCACHE defaults to $GOPATH/pkg/mod which is /root/go/pkg/mod
    # in this throwaway container. Move that into the volume location.
    if [ -d /root/go/pkg/mod ]; then
      cp -a /root/go/pkg/mod/. /opt/deps/go/pkg/mod/
    fi
    chmod -R a+rX /opt/deps/go

    cnt=$(find /opt/deps/go/pkg/mod/cache/download -name "*.info" 2>/dev/null | wc -l)
    {
      echo "{"
      echo "  \"snapshot_date\": \"'"$SNAPSHOT_DATE"'\","
      echo "  \"modules_requested\": $(jq -R -s -c "split(\"\n\") | map(select(length > 0))" /tmp/modules.txt 2>/dev/null || echo "null"),"
      echo "  \"module_info_count\": $cnt"
      echo "}"
    } > /opt/deps/go/manifest.json
    sha256sum /opt/deps/go/manifest.json | awk "{print \$1}" > /opt/deps/go/snapshot-sha256
    echo "[deps-go] $cnt module .info files; manifest sha:"
    cat /opt/deps/go/snapshot-sha256
  '
echo "[deps-go] done"
