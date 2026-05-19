#!/bin/bash
# Strip zstd reference. NOTE: libzstd.so.1 is a NEEDED dependency of cc1 (the gcc
# compiler proper), so we cannot delete it. Instead STUB it: build an empty .so
# with the same soname (while gcc still works), swap the real lib's content for
# the stub. cc1 keeps loading it; the agent's ZSTD_* link/dlopen finds no symbols.
set -u
# 1. /workspace -> executable + docs only
cd /workspace 2>/dev/null && for f in * .[!.]*; do
  case "$f" in executable|*.1|README*|readme*|COPYING*|LICENSE*|docs|man) : ;; *) rm -rf -- "$f" 2>/dev/null ;; esac
done
# 2. binaries
for b in zstd unzstd zstdcat zstdmt; do rm -f /usr/bin/$b /bin/$b /usr/local/bin/$b /sbin/$b 2>/dev/null; done
# 3. STUB libzstd (build before swapping; gcc still works at this point)
printf '' > /tmp/_empty.c
gcc -shared -fPIC -Wl,-soname,libzstd.so.1 -o /tmp/_stub_libzstd.so /tmp/_empty.c 2>/dev/null
if [ -f /tmp/_stub_libzstd.so ]; then
  for real in $(find / -name 'libzstd.so*' 2>/dev/null | grep -v /var/lib/dpkg); do
    rf=$(readlink -f "$real" 2>/dev/null); [ -n "$rf" ] && cp /tmp/_stub_libzstd.so "$rf" 2>/dev/null
  done
fi
# remove dev symlink + headers so -lzstd / #include <zstd.h> also fail
rm -f /usr/lib/*/libzstd.so /usr/lib/libzstd.so /usr/local/lib/libzstd.so /usr/include/zstd*.h 2>/dev/null
ldconfig 2>/dev/null || true
true
