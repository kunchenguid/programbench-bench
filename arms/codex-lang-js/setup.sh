#!/usr/bin/env bash
# codex-pilot-2 activation - JS arm. node comes from pb-toolkit2 (/opt/tk2/node);
# symlink its bins into /usr/local/bin (already on every PATH, login or not).
# npm offline against pb-deps-js. Env in /etc/profile.d covers build-time; the
# node `executable` at test time just needs `node` on PATH (the symlink).
set +e
cat > /etc/profile.d/pb-activate.sh <<'PROF'
export PATH=/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export NPM_CONFIG_OFFLINE=true
export NPM_CONFIG_CACHE=/opt/deps/js/cache
export NPM_CONFIG_AUDIT=false
export NPM_CONFIG_FUND=false
PROF
chmod 644 /etc/profile.d/pb-activate.sh
. /etc/profile.d/pb-activate.sh 2>/dev/null
for b in node npm npx; do
  [ -e /opt/tk2/node/bin/$b ] && ln -sf /opt/tk2/node/bin/$b /usr/local/bin/$b
done
true
