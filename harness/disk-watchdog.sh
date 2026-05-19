#!/usr/bin/env bash
# Real-time disk watchdog for any large eval (codex-pilot-2 and beyond).
#
# WHY: a disk-runaway task (tinycc/ditaa/tarka-xcp + unknown future ones) can
# fill Docker.raw to its cap in well under the 25-min health-check cron's
# window, wedging the daemon and crashing the host. This loop checks free disk
# every ~10s and, the moment it drops below a floor, force-removes running eval
# containers (where the runaway writable layer lives) + prunes dangling images -
# long before the ~0-free wedge. Proven pattern from resume-vc-tail.sh.
#
# Usage:  PB_DISK_FLOOR_GB=50 nohup ./harness/disk-watchdog.sh > /tmp/<run>-watchdog.log 2>&1 &
#         echo $! > /tmp/<run>-watchdog.pid
# Stop:   kill "$(cat /tmp/<run>-watchdog.pid)"
#
# NOTE: `timeout` is not a macOS builtin; this uses a plain sleep loop only.
set -uo pipefail
FLOOR_GB="${PB_DISK_FLOOR_GB:-50}"
INTERVAL="${PB_DISK_WATCH_INTERVAL:-10}"
echo "[disk-watchdog] floor=${FLOOR_GB}GB interval=${INTERVAL}s pid=$$"
while true; do
  free_kb="$(df -k / | awk 'NR==2{print $4}')"
  free_gb=$(( free_kb / 1024 / 1024 ))
  if (( free_gb < FLOOR_GB )); then
    echo "[disk-watchdog] $(date '+%H:%M:%S') free=${free_gb}GB < floor=${FLOOR_GB}GB -> EVICTING"
    # Kill running eval containers (the runaway writable layer lives there).
    ids="$(docker ps -q)"
    [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
    docker image prune -f >/dev/null 2>&1
    # Reclaim cached task images too (they re-pull on demand within rate limit).
    timg="$(docker images 'programbench/*' -q | sort -u)"
    [ -n "$timg" ] && echo "$timg" | xargs -r docker rmi -f >/dev/null 2>&1
    echo "[disk-watchdog] post-evict free=$(( $(df -k / | awk 'NR==2{print $4}') / 1024 / 1024 ))GB"
  fi
  sleep "$INTERVAL"
done
