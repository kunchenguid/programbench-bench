# Auto-prepended by harness/run-codex.sh. Go arm.
#
# Critical: agent compile.sh often does `export PATH=/usr/local/go/bin:$PATH`
# which would demote our toolkit Go (1.22) to behind the eval container's
# Go (1.21). So we don't rely on PATH alone - GOTOOLCHAIN=local tells Go
# to never try auto-downloading a different toolchain regardless of
# go.mod's go directive. GOFLAGS=-buildvcs=false avoids a Go 1.21
# segfault on VCS stamping seen under Docker-on-mac.
# Replace the eval container's Go 1.21 install at /usr/local/go with our
# toolkit's Go 1.22. Symlinks override the directory so any agent PATH
# manipulation that points at /usr/local/go/bin lands on 1.22's binaries.
# Without this, `export PATH=/usr/local/go/bin:$PATH` in the agent's
# compile.sh would demote 1.22 to behind 1.21 and `go 1.22` in go.mod
# wouldn't compile.
if [ -d /opt/all-langs/go ]; then
  rm -rf /usr/local/go
  ln -sfn /opt/all-langs/go /usr/local/go
fi
export PATH=/opt/all-langs/go/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export GOMODCACHE=/opt/deps/go/pkg/mod
export GOPROXY=off
export GOFLAGS=-buildvcs=false
export GOTOOLCHAIN=local
