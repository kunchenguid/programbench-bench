#!/usr/bin/env bash
# Build the read-only docker volume of Maven artifacts for the
# `codex-lang-java` cleanroom at /opt/deps/java/.m2/repository.
#
# Strategy: synthetic pom.xml that declares a curated set of widely-used
# Maven artifacts. `mvn dependency:resolve` pulls each + transitive deps
# into the local repository, which we mount into the cleanroom.

set -euo pipefail

REBUILD=0
IMAGE=pb/clean-lang-java:latest
VOLUME=pb-deps-java

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift 1 ;;
    --top-n)   shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "error: $IMAGE not built" >&2; exit 2; }
if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  if [[ "$REBUILD" -eq 1 ]]; then docker volume rm "$VOLUME"; docker volume create "$VOLUME" >/dev/null
  else echo "[deps-java] $VOLUME exists; pass --rebuild to recreate"; exit 0; fi
else docker volume create "$VOLUME" >/dev/null; fi

SNAPSHOT_DATE="$(date -u +%Y-%m-%d)"

# The build runs with network ON and overrides the offline-mode settings
# from the image's /etc/maven/settings.xml. We pass our own settings file
# via -gs.
docker run --rm --platform linux/amd64 \
  -v "${VOLUME}:/opt/deps/java" \
  --entrypoint bash \
  "$IMAGE" -euxc '
    mkdir -p /opt/deps/java/.m2/repository /tmp/synth/src/main/java/x
    echo "package x; public class X { public static void main(String[] a){} }" > /tmp/synth/src/main/java/x/X.java
    cat > /tmp/synth/online-settings.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <localRepository>/opt/deps/java/.m2/repository</localRepository>
  <offline>false</offline>
</settings>
EOF

    cat > /tmp/synth/pom.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>pb.deps</groupId>
  <artifactId>synth</artifactId>
  <version>0.0.1</version>
  <properties>
    <maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target>
  </properties>
  <dependencies>
    <dependency><groupId>org.apache.commons</groupId><artifactId>commons-lang3</artifactId><version>3.14.0</version></dependency>
    <dependency><groupId>commons-io</groupId><artifactId>commons-io</artifactId><version>2.15.1</version></dependency>
    <dependency><groupId>com.google.guava</groupId><artifactId>guava</artifactId><version>33.0.0-jre</version></dependency>
    <dependency><groupId>com.fasterxml.jackson.core</groupId><artifactId>jackson-databind</artifactId><version>2.16.1</version></dependency>
    <dependency><groupId>com.fasterxml.jackson.core</groupId><artifactId>jackson-annotations</artifactId><version>2.16.1</version></dependency>
    <dependency><groupId>com.fasterxml.jackson.dataformat</groupId><artifactId>jackson-dataformat-yaml</artifactId><version>2.16.1</version></dependency>
    <dependency><groupId>org.slf4j</groupId><artifactId>slf4j-api</artifactId><version>2.0.11</version></dependency>
    <dependency><groupId>org.slf4j</groupId><artifactId>slf4j-simple</artifactId><version>2.0.11</version></dependency>
    <dependency><groupId>ch.qos.logback</groupId><artifactId>logback-classic</artifactId><version>1.4.14</version></dependency>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><version>5.10.1</version></dependency>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter-api</artifactId><version>5.10.1</version></dependency>
    <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter-engine</artifactId><version>5.10.1</version></dependency>
    <dependency><groupId>org.mockito</groupId><artifactId>mockito-core</artifactId><version>5.8.0</version></dependency>
    <dependency><groupId>org.assertj</groupId><artifactId>assertj-core</artifactId><version>3.25.1</version></dependency>
    <dependency><groupId>com.squareup.okhttp3</groupId><artifactId>okhttp</artifactId><version>4.12.0</version></dependency>
    <dependency><groupId>com.squareup.retrofit2</groupId><artifactId>retrofit</artifactId><version>2.9.0</version></dependency>
    <dependency><groupId>org.apache.httpcomponents.client5</groupId><artifactId>httpclient5</artifactId><version>5.3.1</version></dependency>
    <dependency><groupId>com.google.code.gson</groupId><artifactId>gson</artifactId><version>2.10.1</version></dependency>
    <dependency><groupId>org.yaml</groupId><artifactId>snakeyaml</artifactId><version>2.2</version></dependency>
    <dependency><groupId>info.picocli</groupId><artifactId>picocli</artifactId><version>4.7.5</version></dependency>
    <dependency><groupId>com.beust</groupId><artifactId>jcommander</artifactId><version>1.82</version></dependency>
    <dependency><groupId>commons-cli</groupId><artifactId>commons-cli</artifactId><version>1.6.0</version></dependency>
    <dependency><groupId>org.apache.commons</groupId><artifactId>commons-collections4</artifactId><version>4.4</version></dependency>
    <dependency><groupId>org.apache.commons</groupId><artifactId>commons-text</artifactId><version>1.11.0</version></dependency>
    <dependency><groupId>org.apache.commons</groupId><artifactId>commons-csv</artifactId><version>1.10.0</version></dependency>
    <dependency><groupId>com.h2database</groupId><artifactId>h2</artifactId><version>2.2.224</version></dependency>
    <dependency><groupId>org.xerial</groupId><artifactId>sqlite-jdbc</artifactId><version>3.45.1.0</version></dependency>
    <dependency><groupId>org.jetbrains</groupId><artifactId>annotations</artifactId><version>24.1.0</version></dependency>
  </dependencies>
</project>
EOF

    cd /tmp/synth
    # -gs overrides the image global settings (/etc/maven/settings.xml which
    # has offline=true). -o is explicitly NOT passed so we hit the network.
    mvn -gs /tmp/synth/online-settings.xml -B -Dmaven.offline=false dependency:resolve dependency:resolve-plugins 2>&1 | tail -30 >> /opt/deps/java/install-errors.log || echo "[warn] mvn resolve had errors"
    mvn -gs /tmp/synth/online-settings.xml -B -Dmaven.offline=false dependency:get -Dartifact=org.apache.maven.plugins:maven-surefire-plugin:3.2.5 2>/dev/null || true

    chmod -R a+rX /opt/deps/java
    artifact_count=$(find /opt/deps/java/.m2/repository -name "*.jar" 2>/dev/null | wc -l)
    {
      echo "{"
      echo "  \"snapshot_date\": \"'"$SNAPSHOT_DATE"'\","
      echo "  \"artifact_jar_count\": $artifact_count"
      echo "}"
    } > /opt/deps/java/manifest.json
    sha256sum /opt/deps/java/manifest.json | awk "{print \$1}" > /opt/deps/java/snapshot-sha256
    echo "[deps-java] $artifact_count jars"
    cat /opt/deps/java/snapshot-sha256
  '
echo "[deps-java] done"
