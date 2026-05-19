#!/bin/bash
# Memory watchdog (mirrors disk-watchdog.sh). Every ~10s, force-removes any
# single container whose RSS exceeds THRESHOLD GiB. Runaway test suites (e.g.
# johnkerl__miller under the ruby submission, 2026-06-05) balloon toward the
# 31 GiB VM cap and OOM-wedge the Docker daemon - which would kill BOTH the
# 6h re-eval AND the codex-free-tdd agents. The per-test 30s timeout does not
# bound memory, so this is the backstop. Threshold 24 GiB leaves headroom
# below 31; legitimate heavy suites observed at <=7 GiB, so only true runaways
# trip it. Stop: kill $(cat /tmp/codex-pilot-2-memwatch.pid)
THRESHOLD_GIB="${PB_MEM_THRESHOLD_GIB:-24}"
LOG=/tmp/codex-pilot-2-memwatch.log
echo "[mem-watchdog] threshold=${THRESHOLD_GIB}GiB interval=10s pid=$$ $(date '+%F %T')" >> "$LOG"
while true; do
  while read -r id mem _; do
    g=$(printf '%s' "$mem" | grep -oE '^[0-9.]+GiB' | grep -oE '^[0-9.]+')
    [[ -n "$g" ]] || continue
    if awk "BEGIN{exit !($g > $THRESHOLD_GIB)}"; then
      img=$(docker inspect "$id" --format '{{.Config.Image}}' 2>/dev/null)
      echo "[mem-watchdog] $(date '+%H:%M:%S') KILLING $id ($img) at ${g}GiB > ${THRESHOLD_GIB}GiB" >> "$LOG"
      docker rm -f "$id" >> "$LOG" 2>&1
    fi
  done < <(docker stats --no-stream --format '{{.ID}} {{.MemUsage}}' 2>/dev/null)
  sleep 10
done
