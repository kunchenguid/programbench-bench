#!/usr/bin/env bash
# codex-pilot-2 activation - Ruby arm. ruby 3.1 comes from pb-toolkit2
# (/opt/tk2/ruby, built --enable-shared on ubuntu:22.04 so libruby links the
# eval image's glibc). Install thin WRAPPERS in /usr/local/bin that set a NARROW
# LD_LIBRARY_PATH (only /opt/tk2/ruby/lib = libruby + libyaml, NOT glibc, so it
# never poisons the loader the way the debian pb-all-langs-toolkit did) + GEM_PATH.
# Wrappers persist into the eval's committed image so the agent's `executable`
# resolves ruby at TEST time with no ambient env. Offline gems from pb-deps-ruby.
set +e
RB=/opt/tk2/ruby
GEMVER="$("$RB/bin/ruby" -e 'print RUBY_VERSION.split(".")[0,2].join(".")+".0"' 2>/dev/null)"
[ -n "$GEMVER" ] || GEMVER=3.1.0
cat > /etc/profile.d/pb-activate.sh <<PROF
export PATH=/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_LIBRARY_PATH=$RB/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export GEM_PATH=/opt/deps/ruby/installed:$RB/lib/ruby/gems/$GEMVER
export GEM_HOME=/opt/deps/ruby/installed
export BUNDLE_PATH=/opt/deps/ruby/installed
PROF
chmod 644 /etc/profile.d/pb-activate.sh
. /etc/profile.d/pb-activate.sh 2>/dev/null
for t in ruby gem bundle bundler rake irb erb rdoc ri racc; do
  [ -e "$RB/bin/$t" ] || continue
  cat > /usr/local/bin/$t <<EOF
#!/bin/sh
export LD_LIBRARY_PATH=$RB/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export GEM_PATH=/opt/deps/ruby/installed:$RB/lib/ruby/gems/$GEMVER
export GEM_HOME=/opt/deps/ruby/installed
export BUNDLE_PATH=/opt/deps/ruby/installed
exec $RB/bin/$t "\$@"
EOF
  chmod 755 /usr/local/bin/$t
done
true
