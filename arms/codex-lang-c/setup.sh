#!/usr/bin/env bash
# codex-pilot-2 activation - C arm. `:task` ships gcc/make/binutils natively;
# nothing to install. We still drop a profile.d so the agent's `bash -lc`
# login shells get a sane PATH (a login shell resets PATH and would otherwise
# drop /usr/local/cargo/bin etc - irrelevant for C but kept uniform). Runs in
# both the cleanroom (at start) and at eval (injected prelude).
set +e
cat > /etc/profile.d/pb-activate.sh <<'PROF'
export PATH=/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PROF
chmod 644 /etc/profile.d/pb-activate.sh
. /etc/profile.d/pb-activate.sh 2>/dev/null
true
