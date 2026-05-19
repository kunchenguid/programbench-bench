# Auto-prepended by harness/run-codex.sh. Ruby arm.
#
# Install ONLY ruby-prefixed .debs (no java, no python). The ruby* glob
# catches ruby_*, ruby3.1_*, ruby-dev_*, ruby-rubygems_*, etc.; libruby*
# catches libruby_* and libruby3.1_*; rubygems-integration_* is a separate
# helper. --force-depends to skip transitive checks - any required system
# libs are already in the eval container's /usr/lib/x86_64-linux-gnu.
#
# A-fix (env confound, 2026-05-25): also install libyaml-0-2. The eval
# image lacks libyaml, so Ruby's bundled psych makes `require 'yaml'`
# crash at load time before any test logic runs - this was a false-zero
# on ~15 tasks (yq, gomplate, cheat, ...). See
# memory:project_codex-pilot-1-env-confound.
shopt -s nullglob
debs=(/opt/all-langs/debs/ruby*.deb /opt/all-langs/debs/libruby*.deb /opt/all-langs/debs/rubygems-integration_*.deb /opt/all-langs/debs/libyaml-0-2_*.deb)
shopt -u nullglob
if [ ${#debs[@]} -gt 0 ]; then
  dpkg -i --force-depends "${debs[@]}" 2>/dev/null || true
fi
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export GEM_PATH=/opt/deps/ruby/installed:${GEM_PATH:-}

# B-fix (env confound, 2026-05-26): the GEM_PATH export above only applies
# to THIS compile.sh process. When the eval harness later spawns the
# agent's `executable`, GEM_PATH is gone, so deps-volume gems (notably the
# native-ext gem nokogiri) raise `LoadError` at TEST time even though they
# load in the cleanroom - a false-zero on ~5 HTML/XML tasks (htmlq, xq,
# html-to-markdown, monolith, brotli). Fix: stage the offline gem tree into
# the eval ruby's DEFAULT gem dir so `require` resolves them without any
# GEM_PATH at runtime (mirrors how the libyaml .so fix persists). The ABI
# matches (deps gems built for ruby 3.1.0; eval ruby is the force-installed
# Debian 3.1.2). See memory:project_codex-pilot-1-env-confound.
if [ -d /opt/deps/ruby/installed ]; then
  _gemdir="$(ruby -e 'print Gem.dir' 2>/dev/null)"
  [ -n "$_gemdir" ] || _gemdir=/var/lib/gems/3.1.0
  mkdir -p "$_gemdir"
  cp -an /opt/deps/ruby/installed/. "$_gemdir/" 2>/dev/null || true
fi
