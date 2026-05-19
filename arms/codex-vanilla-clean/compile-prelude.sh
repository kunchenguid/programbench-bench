# Auto-prepended by harness/run-codex.sh to the agent's compile.sh before
# scoring, for the codex-vanilla-clean (free-choice) arm.
#
# Because the agent may have chosen ANY language, this is the UNION of all
# the per-language compile-prelude.sh setups, so the eval container can
# build whatever the submission used. It runs inside the upstream task
# image (the eval container), with the pb-all-langs-toolkit volume mounted
# at /opt/all-langs and the per-language deps volumes at /opt/deps/<lang>.
#
# HARD RULE: never install python3*.deb here. The eval framework runs
# pytest with the container's python3; replacing it breaks scoring for
# every task. (Same reason the js/java per-lang preludes skip python3.)

# --- Go: prefer the toolkit's Go 1.22 over the eval image's Go. Symlink
#     over /usr/local/go so agent PATH manipulation still lands on 1.22. ---
if [ -d /opt/all-langs/go ]; then
  rm -rf /usr/local/go
  ln -sfn /opt/all-langs/go /usr/local/go
fi

# --- Node (JS/TS): install nodejs from the staged deb (nodesource bundles
#     npm), then bridge the toolkit's global typescript/ts-node into place
#     so `tsc` / `ts-node` resolve. ---
if ls /opt/all-langs/debs/nodejs_20*.deb >/dev/null 2>&1; then
  dpkg -i --force-depends /opt/all-langs/debs/nodejs_20*.deb 2>/dev/null || true
fi
mkdir -p /usr/local/lib/node_modules
ln -sfn /opt/all-langs/lib/node_modules/typescript /usr/local/lib/node_modules/typescript 2>/dev/null || true
ln -sfn /opt/all-langs/lib/node_modules/ts-node    /usr/local/lib/node_modules/ts-node 2>/dev/null || true
ln -sfn /opt/all-langs/lib/node_modules/typescript/bin/tsc       /usr/local/bin/tsc 2>/dev/null || true
ln -sfn /opt/all-langs/lib/node_modules/typescript/bin/tsserver  /usr/local/bin/tsserver 2>/dev/null || true
ln -sfn /opt/all-langs/lib/node_modules/ts-node/dist/bin.js       /usr/local/bin/ts-node 2>/dev/null || true

# --- Java: install openjdk-17 + maven + helper libs from staged debs.
#     Skip python3/ruby/nodejs debs (handled elsewhere or would clobber). ---
shopt -s nullglob
_jdebs=(
  /opt/all-langs/debs/openjdk-17*.deb
  /opt/all-langs/debs/maven_*.deb
  /opt/all-langs/debs/java-common_*.deb
  /opt/all-langs/debs/ca-certificates-java_*.deb
  /opt/all-langs/debs/lib*-java_*.deb
)
shopt -u nullglob
if [ ${#_jdebs[@]} -gt 0 ]; then
  dpkg -i --force-depends "${_jdebs[@]}" 2>/dev/null || true
fi

# --- Ruby: install ruby + bundler debs from staged debs, plus libyaml
#     (A-fix: the eval image lacks libyaml-0-2, so `require 'yaml'` would
#     crash; the deb is staged in the toolkit). Skip python3 debs. ---
shopt -s nullglob
_rdebs=(
  /opt/all-langs/debs/ruby*.deb
  /opt/all-langs/debs/libruby*.deb
  /opt/all-langs/debs/rubygems-integration_*.deb
  /opt/all-langs/debs/libyaml-0-2_*.deb
)
shopt -u nullglob
if [ ${#_rdebs[@]} -gt 0 ]; then
  dpkg -i --force-depends "${_rdebs[@]}" 2>/dev/null || true
fi

# --- C: install the -dev headers + build tools the eval image lacks (the
#     agent may have chosen C). UBUNTU debs (matching the eval base) staged
#     under /opt/all-langs/debs/cdev. Exclude core libc debs to avoid a
#     glibc clash. (A-fix, env confound 2026-05-25.) ---
if [ -d /opt/all-langs/debs/cdev ]; then
  shopt -s nullglob
  _cdebs=()
  for _d in /opt/all-langs/debs/cdev/*.deb; do
    case "$(basename "$_d")" in
      libc6-dev_*|libc-dev-bin_*|libcrypt-dev_*) continue ;;
    esac
    _cdebs+=("$_d")
  done
  shopt -u nullglob
  [ ${#_cdebs[@]} -gt 0 ] && dpkg -i --force-depends --force-overwrite "${_cdebs[@]}" 2>/dev/null || true
fi

# --- Python: install python3.10-venv (eval image lacks it). cp310 wheels
#     were added to the wheelhouse. Do NOT touch /usr/bin/python3 (pytest
#     uses it). (A-fix, env confound 2026-05-25.) ---
if [ -d /opt/all-langs/debs/pyvenv ]; then
  shopt -s nullglob
  _vdebs=(/opt/all-langs/debs/pyvenv/*.deb)
  shopt -u nullglob
  [ ${#_vdebs[@]} -gt 0 ] && dpkg -i --force-depends "${_vdebs[@]}" 2>/dev/null || true
fi

# --- Rust: cargo offline config redirecting crates.io to the vendored dir. ---
export CARGO_HOME=${CARGO_HOME:-/usr/local/cargo}
export RUSTUP_HOME=${RUSTUP_HOME:-/usr/local/rustup}
mkdir -p "$CARGO_HOME"
cat > "$CARGO_HOME/config.toml" <<'CARGOCFG'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "/opt/deps/rust/vendor"

[net]
offline = true
CARGOCFG

# --- Merged environment for every toolchain (single PATH covering all). ---
export PATH=/usr/local/cargo/bin:/opt/all-langs/go/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Go
export GOMODCACHE=/opt/deps/go/pkg/mod
export GOPROXY=off
export GOFLAGS=-buildvcs=false
export GOTOOLCHAIN=local
# Python
export PIP_NO_INDEX=1
export PIP_FIND_LINKS=/opt/deps/python/wheels
# JS/TS
export NPM_CONFIG_OFFLINE=true
export NPM_CONFIG_CACHE=/opt/deps/js/cache
# Java
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export MAVEN_OPTS="-Dmaven.repo.local=/opt/deps/java/.m2/repository"
# Ruby
export GEM_PATH=/opt/deps/ruby/installed:/var/lib/gems/3.1.0:/usr/lib/ruby/gems/3.1.0:${GEM_PATH:-}
