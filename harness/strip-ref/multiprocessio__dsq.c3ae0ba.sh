#!/bin/bash
# Strip the dsq reference AND its embedded SQL engine from the cleanroom.
# dsq runs SQL over CSV/JSON/etc by embedding a SQLite engine; every arm wrapped
# that engine instead of reimplementing a query layer (python `import sqlite3`,
# go mattn/go-sqlite3 cgo, java sqlite-jdbc, rust libsqlite3-sys/rusqlite, ruby
# sqlite3 gem, ctypes/dlopen libsqlite3). Remove the engine from ALL sources so
# the agent must implement the SQL/query layer itself. Keep only the
# execute-only ./executable + docs. Toolchains otherwise untouched.
set -u
export CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
# 1. /workspace -> keep only executable + docs
cd /workspace 2>/dev/null && for f in * .[!.]*; do
  case "$f" in executable|*.1|README*|readme*|COPYING*|LICENSE*|docs|man) : ;; *) rm -rf -- "$f" 2>/dev/null ;; esac
done
# 2. dsq + sqlite system binaries
for b in dsq sqlite3; do rm -f /usr/bin/$b /bin/$b /usr/local/bin/$b /sbin/$b /usr/sbin/$b 2>/dev/null; done
# 3. sqlite engine shared libs (breaks python `import sqlite3`, ruby gem, C/dlopen)
for l in libsqlite3 libduckdb; do
  rm -f /usr/lib/*/${l}.so* /usr/lib/${l}.so* /usr/local/lib/${l}.so* /lib/*/${l}.so* 2>/dev/null
  for hit in $(find / -name "${l}.so*" 2>/dev/null | grep -v '/var/lib/dpkg'); do rm -f "$hit" 2>/dev/null; done
done
# 4. bundled sqlite engines in language package caches (cgo / rust -sys / jdbc)
rm -rf /opt/deps/go/pkg/mod/github.com/mattn/go-sqlite3* 2>/dev/null
rm -rf /opt/deps/go/pkg/mod/modernc.org/sqlite* 2>/dev/null
rm -rf "$CARGO_HOME"/registry/*/rusqlite* "$CARGO_HOME"/registry/*/libsqlite3-sys* 2>/dev/null
for hit in $(find / \( -iname 'sqlite*jdbc*.jar' -o -iname '*sqlite*.jar' -o -iname '*duckdb*.jar' \) 2>/dev/null | grep -v '/var/lib/dpkg'); do rm -f "$hit" 2>/dev/null; done
true
