#!/usr/bin/env bash
# codex-pilot-2 activation - codex-free (free language choice). Union of every
# per-language activation. Native in `:task`: gcc, rust (/usr/local/cargo), go
# (/usr/local/go), python3.10. Added from pb-toolkit2 (/opt/tk2): node/ts, JDK17,
# maven, ruby 3.1. Offline deps from all pb-deps-* at /opt/deps/<lang>.
# Robust to the non-root `agent` user: build-time env in world-readable
# /etc/profile.d, world-readable configs, ruby wrappers for test-time libs.
set +e
RB=/opt/tk2/ruby
JDK=/opt/tk2/jdk
GEMVER="$("$RB/bin/ruby" -e 'print RUBY_VERSION.split(".")[0,2].join(".")+".0"' 2>/dev/null)"
[ -n "$GEMVER" ] || GEMVER=3.1.0

cat > /etc/profile.d/pb-activate.sh <<PROF
export PATH=/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export CARGO_HOME=/usr/local/cargo
export RUSTUP_HOME=/usr/local/rustup
export GOMODCACHE=/opt/deps/go/pkg/mod
export GOPROXY=off
export GOFLAGS=-buildvcs=false
export GOTOOLCHAIN=local
export NPM_CONFIG_OFFLINE=true
export NPM_CONFIG_CACHE=/opt/deps/js/cache
export JAVA_HOME=$JDK
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LD_LIBRARY_PATH=$RB/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export GEM_PATH=/opt/deps/ruby/installed:$RB/lib/ruby/gems/$GEMVER
export GEM_HOME=/opt/deps/ruby/installed
PROF
chmod 644 /etc/profile.d/pb-activate.sh
. /etc/profile.d/pb-activate.sh 2>/dev/null

# Offline pip - INLINE only (NOT in profile.d): the eval sources profile.d via
# `bash -lc`, and PIP_NO_INDEX there blocks its own `pip install pytest-timeout
# pytest-rerunfailures` -> all tests not_run. Inline reaches the agent's
# compile.sh; an agent-home pip.conf (uid agent) covers interactive use without
# affecting the root-run eval. (codex-pilot-2-pilot root-cause, 2026-05-27.)
export PIP_NO_INDEX=1
export PIP_FIND_LINKS=/opt/deps/python/wheels
if id agent >/dev/null 2>&1; then
  mkdir -p /home/agent/.config/pip
  printf '[global]\nno-index = true\nfind-links = /opt/deps/python/wheels\n' > /home/agent/.config/pip/pip.conf
  chown -R agent:agent /home/agent/.config 2>/dev/null; chmod -R a+rX /home/agent/.config 2>/dev/null
fi

# Rust offline config
mkdir -p /usr/local/cargo
cat > /usr/local/cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = "vendored-sources"
[source.vendored-sources]
directory = "/opt/deps/rust/vendor"
[net]
offline = true
EOF
chmod 644 /usr/local/cargo/config.toml

# Python offline pip: env only (PIP_NO_INDEX/PIP_FIND_LINKS in profile.d above +
# inline export at eval compile.sh). DELIBERATELY no global /etc/pip.conf - a
# no-index pip.conf persists into the eval image and blocks programbench's
# eval-time `pip install pytest-timeout pytest-rerunfailures` -> ALL tests
# not_run (false zero). Caught in codex-pilot-2-pilot, 2026-05-27.

# Node (JS/TS) symlinks
for b in node npm npx tsc ts-node tsserver; do
  [ -e /opt/tk2/node/bin/$b ] && ln -sf /opt/tk2/node/bin/$b /usr/local/bin/$b
done

# Ruby wrappers (narrow LD path so test-time `executable` resolves ruby)
if [ -x "$RB/bin/ruby" ]; then
  for t in ruby gem bundle bundler rake irb erb rdoc ri racc; do
    [ -e "$RB/bin/$t" ] || continue
    cat > /usr/local/bin/$t <<EOF
#!/bin/sh
export LD_LIBRARY_PATH=$RB/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export GEM_PATH=/opt/deps/ruby/installed:$RB/lib/ruby/gems/$GEMVER
export GEM_HOME=/opt/deps/ruby/installed
export BUNDLE_PATH=/opt/deps/ruby/installed
exec $RB/bin/$t "\$@"
EOF
    chmod 755 /usr/local/bin/$t
  done
fi

# Java JDK symlinks + mvn wrapper + offline m2
if [ -d "$JDK/bin" ]; then
  for b in "$JDK"/bin/*; do [ -e "$b" ] && ln -sf "$b" /usr/local/bin/"$(basename "$b")"; done
  mkdir -p /usr/local/etc
  cat > /usr/local/etc/pb-m2-settings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <localRepository>/opt/deps/java/.m2/repository</localRepository>
  <offline>true</offline>
</settings>
EOF
  chmod 644 /usr/local/etc/pb-m2-settings.xml
  cat > /usr/local/bin/mvn <<EOF
#!/bin/sh
export JAVA_HOME=$JDK
exec /opt/tk2/maven/bin/mvn -s /usr/local/etc/pb-m2-settings.xml "\$@"
EOF
  chmod 755 /usr/local/bin/mvn
fi
true
