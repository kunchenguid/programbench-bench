# Auto-prepended by harness/run-codex.sh to the agent's compile.sh before
# scoring. C arm: the eval container already has gcc.
#
# A-fix (env confound, 2026-05-25): the C cleanroom (pb/clean-lang-c) has
# a broad set of -dev headers (libcurl, openssl, sqlite3, ncurses, pcre2,
# libxml2, ...) that the eval container (the upstream task image) lacks.
# The agent builds against them in the cleanroom, then compile.sh re-runs
# at eval time in the upstream image and fails with `fatal error:
# <lib>.h: No such file or directory` - the single biggest false-zero
# bucket (~32 C tasks). We stage those -dev debs (+ their runtime lib
# deps) under /opt/all-langs/debs/cdev and dpkg-install them here.
#
# We EXCLUDE the core libc dev debs (libc6-dev, libc-dev-bin, libcrypt-dev)
# - gcc + libc are already in the eval container, and forcing a possibly
# mismatched glibc-dev could break compilation worse than the missing
# headers. --force-depends because the eval image already carries the
# base runtime libs; we only need the headers + the few runtime .so's.
if [ -d /opt/all-langs/debs/cdev ]; then
  shopt -s nullglob
  _cdebs=()
  for _d in /opt/all-langs/debs/cdev/*.deb; do
    case "$(basename "$_d")" in
      libc6-dev_*|libc-dev-bin_*|libcrypt-dev_*) continue ;;
    esac
    _cdebs+=("$_d")
  done
  shopt -u nullglob
  if [ ${#_cdebs[@]} -gt 0 ]; then
    dpkg -i --force-depends --force-overwrite "${_cdebs[@]}" 2>/dev/null || true
  fi
fi
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
