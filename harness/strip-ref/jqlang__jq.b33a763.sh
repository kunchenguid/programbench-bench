#!/bin/bash
# Strip the jq REFERENCE from the cleanroom so the agent must reimplement
# (paper-faithful: keep only the execute-only ./executable + docs).
set -u
TOOL=jq
# 1. system binaries on PATH
rm -f /usr/bin/$TOOL /bin/$TOOL /usr/local/bin/$TOOL /sbin/$TOOL 2>/dev/null
# 2. system shared libraries (the reference engine)
rm -f /usr/lib/*/lib$TOOL.so* /usr/lib/lib$TOOL.so* /usr/local/lib/lib$TOOL.so* /lib/*/lib$TOOL.so* 2>/dev/null
# 3. /workspace: keep ONLY the execute-only executable + docs; remove source,
#    build tree, .git history, compiled libs (everything that reveals/enables the impl)
cd /workspace || exit 0
for f in * .[!.]*; do
  case "$f" in
    executable|*.1|README*|readme*|COPYING*|LICENSE*|docs|man) : ;;   # keep
    *) rm -rf -- "$f" 2>/dev/null ;;                                   # remove
  esac
done
true
