# Auto-prepended by harness/run-codex.sh. Rust arm: eval container ships
# rustup/cargo at /usr/local/cargo. Our pb-deps-rust volume contains a
# vendored crate snapshot at /opt/deps/rust/vendor.
export PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export CARGO_HOME=${CARGO_HOME:-/usr/local/cargo}
export RUSTUP_HOME=${RUSTUP_HOME:-/usr/local/rustup}
# Write a cargo config that redirects crates.io to the vendored dir. The
# config goes in $CARGO_HOME so any `cargo build` in any subdir picks it
# up; net.offline=true forces failure-fast if a crate isn't vendored.
mkdir -p "$CARGO_HOME"
cat > "$CARGO_HOME/config.toml" <<'CARGOCFG'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "/opt/deps/rust/vendor"

[net]
offline = true
CARGOCFG
