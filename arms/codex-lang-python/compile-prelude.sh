# Auto-prepended by harness/run-codex.sh. Python arm: eval container has
# python3 (the upstream cleanroom carries it), plus our pb-deps-python
# volume mounts the pip wheelhouse at /opt/deps/python so vendored wheels
# resolve offline.
#
# B-fix (env confound, 2026-05-26): the cleanroom python is now pinned to
# CPython 3.10 (Dockerfile.clean-lang-python / .clean-lang-all copy it from
# python:3.10-slim-bookworm) to MATCH this eval container (Ubuntu 22.04,
# python 3.10). The agent now develops on the same interpreter that scores
# it, so the version-skew false-zero class (e.g. reaching for 3.11-only
# `tomllib`) is removed at the source. The two eval-side band-aids below
# are still required because the EVAL image ships neither the venv
# bootstrap nor our wheels:
#   1. python3.10-venv is not installed here -> `python3 -m venv` fails with
#      "ensurepip is not available". Install it from the staged ubuntu deb.
#   2. cp310 wheels in the wheelhouse so `pip install <pkg>` resolves on
#      3.10 offline.
# (Supersedes the 2026-05-25 A-fix, which instead patched around a 3.11
#  cleanroom.) See memory:project_codex-pilot-1-env-confound.
if [ -d /opt/all-langs/debs/pyvenv ]; then
  shopt -s nullglob
  _vdebs=(/opt/all-langs/debs/pyvenv/*.deb)
  shopt -u nullglob
  [ ${#_vdebs[@]} -gt 0 ] && dpkg -i --force-depends "${_vdebs[@]}" 2>/dev/null || true
fi
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PIP_NO_INDEX=1
export PIP_FIND_LINKS=/opt/deps/python/wheels
