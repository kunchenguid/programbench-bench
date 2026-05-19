#!/usr/bin/env bash
# codex-pilot-2 activation - Go arm. Go is native in `:task` (/usr/local/go).
# Point the module cache at the offline snapshot (pb-deps-go) and disable the
# proxy. Env in /etc/profile.d (login shells + sourced inline for eval compile.sh).
set +e
cat > /etc/profile.d/pb-activate.sh <<'PROF'
export PATH=/usr/local/go/bin:/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export GOMODCACHE=/opt/deps/go/pkg/mod
export GOPROXY=off
export GOFLAGS=-buildvcs=false
export GOTOOLCHAIN=local
PROF
chmod 644 /etc/profile.d/pb-activate.sh
. /etc/profile.d/pb-activate.sh 2>/dev/null
true
