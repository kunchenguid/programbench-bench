#!/usr/bin/env bash
# codex-pilot-2 activation - TS arm. Same node as JS (pb-toolkit2) plus the
# global typescript/ts-node bins the toolkit build put under /opt/tk2/node/bin.
# Symlink all into /usr/local/bin; npm offline against pb-deps-ts.
set +e
cat > /etc/profile.d/pb-activate.sh <<'PROF'
export PATH=/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export NPM_CONFIG_OFFLINE=true
export NPM_CONFIG_CACHE=/opt/deps/ts/cache
export NPM_CONFIG_AUDIT=false
export NPM_CONFIG_FUND=false
PROF
chmod 644 /etc/profile.d/pb-activate.sh
. /etc/profile.d/pb-activate.sh 2>/dev/null
for b in node npm npx tsc ts-node tsserver; do
  [ -e /opt/tk2/node/bin/$b ] && ln -sf /opt/tk2/node/bin/$b /usr/local/bin/$b
done
true
