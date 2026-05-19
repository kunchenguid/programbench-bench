# Auto-prepended by harness/run-codex.sh. TS arm. Install nodejs from
# .debs, then global-install typescript + ts-node from the offline cache.
#
# Critical: nodesource's npm puts global binaries under
# `$(npm config get prefix)/bin`, which is typically /usr/bin on Debian
# but can be /usr/local on other layouts. Prepend the resolved prefix to
# PATH after the global install so `tsc` and `ts-node` resolve.
if [ -f /opt/all-langs/debs/nodejs_20*.deb ]; then
  dpkg -i --force-depends /opt/all-langs/debs/nodejs_20*.deb 2>/dev/null || true
fi
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export NPM_CONFIG_OFFLINE=true
export NPM_CONFIG_CACHE=/opt/deps/ts/cache
# typescript + ts-node are pre-installed in the toolkit volume at
# /opt/all-langs/lib/node_modules/. Bridge them into /usr/local/lib/node_modules
# (so `require("typescript")` works) and symlink the executables into
# /usr/local/bin so `tsc` / `ts-node` resolve on the eval-time PATH.
# (npm install --global --offline doesn't reliably find packages by name
# in an opaque cache; direct symlinks are more robust.)
mkdir -p /usr/local/lib/node_modules
ln -sfn /opt/all-langs/lib/node_modules/typescript /usr/local/lib/node_modules/typescript 2>/dev/null || true
ln -sfn /opt/all-langs/lib/node_modules/ts-node /usr/local/lib/node_modules/ts-node 2>/dev/null || true
ln -sfn /opt/all-langs/lib/node_modules/typescript/bin/tsc /usr/local/bin/tsc 2>/dev/null || true
ln -sfn /opt/all-langs/lib/node_modules/typescript/bin/tsserver /usr/local/bin/tsserver 2>/dev/null || true
ln -sfn /opt/all-langs/lib/node_modules/ts-node/dist/bin.js /usr/local/bin/ts-node 2>/dev/null || true
