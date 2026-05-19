#!/bin/bash
# Strip the reference tool from the cleanroom (de-pollution re-run).
# Keep only the execute-only ./executable + docs; remove system binary, libs,
# workspace source/build-tree/.git/.libs/embedded-binary. Toolchain untouched.
set -u
BINS="chafa"
LIBS="libchafa"
# 1. /workspace -> keep only executable + docs (handles embedded ref binary, source, build tree, .git, .libs)
cd /workspace 2>/dev/null && for f in * .[!.]*; do
  case "$f" in executable|*.1|README*|readme*|COPYING*|LICENSE*|docs|man) : ;; *) rm -rf -- "$f" 2>/dev/null ;; esac
done
# 2. system binaries
for b in $BINS; do rm -f /usr/bin/$b /bin/$b /usr/local/bin/$b /sbin/$b /usr/sbin/$b 2>/dev/null; done
# 3. system libraries (named + find-sweep for stragglers)
for l in $LIBS; do
  rm -f /usr/lib/*/${l}.so* /usr/lib/${l}.so* /usr/local/lib/${l}.so* /lib/*/${l}.so* 2>/dev/null
  for hit in $(find / -name "${l}.so*" 2>/dev/null | grep -v '/var/lib/dpkg'); do rm -f "$hit" 2>/dev/null; done
done
true
