#!/bin/bash
# Strip the htop reference so the agent must reimplement it (the tdd arm was
# caught copy_binary-ing the provided htop). Remove the system binary + any
# htop lib, and reduce /workspace to the execute-only ./executable + docs so
# there is no readable binary to copy/ship. Toolchains untouched.
set -u
TOOL=htop
for b in $TOOL; do rm -f /usr/bin/$b /bin/$b /usr/local/bin/$b /sbin/$b /usr/sbin/$b 2>/dev/null; done
rm -f /usr/lib/*/lib$TOOL.so* /usr/local/lib/lib$TOOL.so* /lib/*/lib$TOOL.so* 2>/dev/null
cd /workspace || exit 0
for f in * .[!.]*; do
  case "$f" in executable|*.1|README*|readme*|COPYING*|LICENSE*|docs|man) : ;; *) rm -rf -- "$f" 2>/dev/null ;; esac
done
true
