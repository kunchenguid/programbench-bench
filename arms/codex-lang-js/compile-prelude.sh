# Auto-prepended by harness/run-codex.sh. JS arm.
#
# Install ONLY the nodejs deb (nodesource's package bundles npm). Critically
# do NOT install other staged .debs - the cache transitively contains
# python3*.deb (pulled in as deps of openjdk/maven), which would REPLACE
# the eval container's python3. The eval framework itself uses python3 to
# run pytest, so swapping it breaks scoring entirely.
if [ -f /opt/all-langs/debs/nodejs_20*.deb ]; then
  dpkg -i --force-depends /opt/all-langs/debs/nodejs_20*.deb 2>/dev/null || true
fi
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export NPM_CONFIG_OFFLINE=true
export NPM_CONFIG_CACHE=/opt/deps/js/cache
