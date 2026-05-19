#!/usr/bin/env bash
# codex-pilot-2 activation - Rust arm. cargo/rustc 1.92 are native in `:task`
# (/usr/local/cargo). Point cargo at the offline vendored crates (pb-deps-rust).
# Build-time env goes in /etc/profile.d (read by the agent's `bash -lc` login
# shells, which otherwise drop /usr/local/cargo/bin from PATH) and is sourced
# inline so the eval's compile.sh gets it too.
set +e
cat > /etc/profile.d/pb-activate.sh <<'PROF'
export PATH=/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export CARGO_HOME=/usr/local/cargo
export RUSTUP_HOME=/usr/local/rustup
PROF
chmod 644 /etc/profile.d/pb-activate.sh
. /etc/profile.d/pb-activate.sh 2>/dev/null
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
true
