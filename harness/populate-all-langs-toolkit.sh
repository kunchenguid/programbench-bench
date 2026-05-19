#!/usr/bin/env bash
# Populate the pb-all-langs-toolkit docker volume from
# pb/all-langs-toolkit:builder. The volume gets mounted read-only at
# /opt/all-langs in programbench's eval containers (via the
# harness/score-with-toolkit.py wrapper).
#
# Layout in the volume:
#   /bin      - node, npm, npx, tsc, ts-node, ruby, gem, java, javac, mvn ...
#   /lib      - support libraries (Ruby's, Java's jvm tree, node_modules, ...)
#   /share    - share/man data
#   /include  - (intentionally omitted; eval container shouldn't compile against these headers)
#
# Agent compile.sh should add /opt/all-langs/bin to PATH and
# /opt/all-langs/lib/x86_64-linux-gnu to LD_LIBRARY_PATH.

set -euo pipefail

IMAGE=pb/all-langs-toolkit:builder
VOLUME=pb-all-langs-toolkit
REBUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "error: $IMAGE not built. Run:" >&2
  echo "  docker build --platform linux/amd64 -t $IMAGE -f harness/sandbox/Dockerfile.all-langs-toolkit harness/sandbox" >&2
  exit 2
}

if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  if [[ "$REBUILD" -eq 1 ]]; then
    echo "[toolkit] removing existing volume"
    docker volume rm "$VOLUME"
    docker volume create "$VOLUME" >/dev/null
  else
    echo "[toolkit] $VOLUME already exists; pass --rebuild to recreate"
    exit 0
  fi
else
  docker volume create "$VOLUME" >/dev/null
fi

docker run --rm --platform linux/amd64 \
  -v "${VOLUME}:/dst" \
  --entrypoint bash \
  "$IMAGE" -euxc '
    # Copy the relevant /usr subdirs into the volume root. The volume mount
    # point inside eval containers is /opt/all-langs/, so /dst/bin becomes
    # /opt/all-langs/bin/ etc.
    cp -a /usr/bin /dst/
    cp -a /usr/lib /dst/
    cp -a /usr/share /dst/

    # Go 1.22 (installed at /usr/local/go in the builder; lands at
    # /opt/all-langs/go in the eval container).
    if [ -d /usr/local/go ]; then
      cp -a /usr/local/go /dst/go
    fi

    # Pre-staged .deb files for ruby/openjdk/maven/nodejs (and their
    # transitive deps). Built by the deb-stage in Dockerfile.all-langs-toolkit
    # and copied to /staged-debs in the final image. Agent compile.sh
    # installs these into the eval container via dpkg -i to get a native
    # install of runtimes the upstream cleanroom does not provide.
    if [ -d /staged-debs ]; then
      mkdir -p /dst/debs
      cp /staged-debs/*.deb /dst/debs/ 2>/dev/null || true
    fi
    # Java JDK lives under /usr/lib/jvm — already covered by cp -a /usr/lib.
    # Same for /usr/lib/node_modules and /usr/lib/ruby.

    # Ensure the dynamic linker is reachable. Programbench eval containers
    # have their own /lib64/ld-linux-x86-64.so.2, but the binaries we
    # copied are built against the SAME Debian 12 base, so this should
    # Just Work.

    # Debian alternatives symlinks: many JDK binaries (java, javac, javadoc,
    # jar, keytool, ...) are symlinked through /etc/alternatives/<name>, which
    # is not in our volume. Rewrite them to point at the actual binaries
    # inside /opt/all-langs/lib/jvm/...
    for f in /dst/bin/*; do
      [ -L "$f" ] || continue
      target=$(readlink "$f")
      [ "${target#/etc/alternatives/}" = "$target" ] && continue
      real=$(readlink -f "/etc/alternatives/${target#/etc/alternatives/}" 2>/dev/null)
      [ -z "$real" ] || [ ! -e "$real" ] && continue
      # /usr/lib/... -> /opt/all-langs/lib/...
      rel="${real#/usr/}"
      ln -sf "/opt/all-langs/$rel" "$f"
    done

    # Maven uses several files from /etc/maven (m2.conf, the conf/logging
    # tree, settings.xml). Copy /etc/maven into the volume and rewrite the
    # absolute-path symlinks share/maven/bin/m2.conf and share/maven/conf
    # to point at /opt/all-langs/etc/maven.
    if [ -d /etc/maven ]; then
      mkdir -p /dst/etc
      cp -a /etc/maven /dst/etc/
      if [ -L /dst/share/maven/bin/m2.conf ]; then
        ln -sfn /opt/all-langs/etc/maven/m2.conf /dst/share/maven/bin/m2.conf
      fi
      if [ -L /dst/share/maven/conf ]; then
        ln -sfn /opt/all-langs/etc/maven /dst/share/maven/conf
      fi
    fi

    chmod -R a+rX /dst

    echo "--- toolkit volume layout ---"
    du -sh /dst
    ls /dst/bin | grep -E "^(node|npm|npx|tsc|ts-node|ruby|gem|java|javac|mvn|bundle)$" | sort
    echo "--- size by subdir ---"
    du -sh /dst/* | head -20
  '

echo "[toolkit] populated. Total volume size:"
docker run --rm -v "${VOLUME}:/d" --entrypoint sh alpine -c 'du -sh /d'
