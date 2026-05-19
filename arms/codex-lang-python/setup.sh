#!/usr/bin/env bash
# codex-pilot-2 activation - Python arm. Python 3.10 is native in `:task` (the
# exact interpreter that scores the submission - no version skew).
#
# OFFLINE PIP, done carefully (root-cause of a codex-pilot-2-pilot false-zero,
# 2026-05-27): programbench runs EVERY eval step via `bash -lc` (login shell),
# which sources /etc/profile.d/*. So anything we put in profile.d also applies to
# the eval's OWN `pip install pytest-timeout pytest-rerunfailures` step - and
# PIP_NO_INDEX there blocks it (PyPI unreachable) -> pytest rejects --timeout ->
# no results.xml -> ALL tests not_run. Likewise a global /etc/pip.conf no-index.
# So we must NOT force offline pip globally. Instead:
#   - profile.d carries PATH only (safe for the eval),
#   - PIP_NO_INDEX/FIND_LINKS are exported INLINE here, which reaches the agent's
#     compile.sh (this prelude runs inside it) but NOT the eval's separate
#     bash -lc pip step,
#   - an AGENT-home-scoped pip.conf (uid agent) gives the interactive agent
#     offline pip without affecting the root-run eval.
set +e
cat > /etc/profile.d/pb-activate.sh <<'PROF'
export PATH=/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PROF
chmod 644 /etc/profile.d/pb-activate.sh
. /etc/profile.d/pb-activate.sh 2>/dev/null

# Inline (compile.sh-scoped) offline pip - does NOT leak to the eval's pip step.
export PIP_NO_INDEX=1
export PIP_FIND_LINKS=/opt/deps/python/wheels
export PIP_DISABLE_PIP_VERSION_CHECK=1

# Agent-scoped offline pip (uid agent; never read by the root-run eval).
if id agent >/dev/null 2>&1; then
  mkdir -p /home/agent/.config/pip
  cat > /home/agent/.config/pip/pip.conf <<'EOF'
[global]
no-index = true
find-links = /opt/deps/python/wheels
disable-pip-version-check = true
EOF
  chown -R agent:agent /home/agent/.config 2>/dev/null
  chmod -R a+rX /home/agent/.config 2>/dev/null
fi
true
