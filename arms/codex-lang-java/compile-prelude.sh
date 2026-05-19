# Auto-prepended by harness/run-codex.sh. Java arm.
#
# Install openjdk-17 + maven + Java helper libs ONLY. Skip python3*.deb
# (would replace the eval container's python3 and break pytest) and skip
# the ruby/nodejs debs (not needed). --force-depends to skip transitive
# checks - any required system libs are already in the eval container.
shopt -s nullglob
debs=(
  /opt/all-langs/debs/openjdk-17*.deb
  /opt/all-langs/debs/maven_*.deb
  /opt/all-langs/debs/java-common_*.deb
  /opt/all-langs/debs/ca-certificates-java_*.deb
  /opt/all-langs/debs/lib*-java_*.deb
  /opt/all-langs/debs/libcommons-*-java_*.deb
  /opt/all-langs/debs/libmaven-*-java_*.deb
  /opt/all-langs/debs/libmaven*-core-java_*.deb
)
shopt -u nullglob
if [ ${#debs[@]} -gt 0 ]; then
  dpkg -i --force-depends "${debs[@]}" 2>/dev/null || true
fi
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export MAVEN_OPTS="-Dmaven.repo.local=/opt/deps/java/.m2/repository"

# B-fix (env confound, 2026-05-26): the eval container has LANG unset
# (charmap ANSI_X3.4-1968 = US-ASCII), so `javac` defaults its source
# encoding to ASCII and dies with "unmappable character for encoding
# US-ASCII" on any non-ASCII literal the agent wrote (the dot/bullet/micro/
# warning glyphs in fx, revive, dog, tree-sitter) -> compile_failed. Force
# a UTF-8 locale so javac (and the JVM I/O at test time) default to UTF-8,
# instead of relying on the agent to remember `javac -encoding UTF-8`.
# (We do NOT set JAVA_TOOL_OPTIONS - it prints a "Picked up ..." line to
# stderr that would break output-matching tests.)
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
