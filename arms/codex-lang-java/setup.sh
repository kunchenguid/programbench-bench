#!/usr/bin/env bash
# codex-pilot-2 activation - Java arm. Temurin JDK 17 from pb-toolkit2
# (/opt/tk2/jdk), Maven from /opt/tk2/maven. The JDK is self-contained, so plain
# /usr/local/bin symlinks work (java self-locates JAVA_HOME from the resolved
# path at test time). mvn needs JAVA_HOME so it gets a wrapper. Offline m2 repo
# config lives in a world-readable path (the non-root agent can't read /root).
set +e
JDK=/opt/tk2/jdk
cat > /etc/profile.d/pb-activate.sh <<PROF
export PATH=/usr/local/cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export JAVA_HOME=$JDK
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
PROF
chmod 644 /etc/profile.d/pb-activate.sh
. /etc/profile.d/pb-activate.sh 2>/dev/null
for b in "$JDK"/bin/*; do
  [ -e "$b" ] && ln -sf "$b" /usr/local/bin/"$(basename "$b")"
done
mkdir -p /usr/local/etc
cat > /usr/local/etc/pb-m2-settings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <localRepository>/opt/deps/java/.m2/repository</localRepository>
  <offline>true</offline>
</settings>
EOF
chmod 644 /usr/local/etc/pb-m2-settings.xml
cat > /usr/local/bin/mvn <<EOF
#!/bin/sh
export JAVA_HOME=$JDK
exec /opt/tk2/maven/bin/mvn -s /usr/local/etc/pb-m2-settings.xml "\$@"
EOF
chmod 755 /usr/local/bin/mvn
true
