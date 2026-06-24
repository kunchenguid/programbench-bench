#!/usr/bin/env bash
# Kills eval containers older than MAX_AGE_S (default 5400s/90min). At a 6h
# per-branch timeout, unmapped hang/TUI tasks (broot/nnn/lazygit/...) would
# block a worker for 6h; this bounds them. 90min >> any legit CLI test-branch
# runtime, so it is score-equivalent to 6h (a container still alive at 90min is
# hanging and would be not_run at 6h anyway) while avoiding multi-hour stalls.
MAX_AGE_S="${PB_HANG_MAX_AGE_S:-5400}"
LOG="${PB_HANG_LOG:-/tmp/codex-pilot-2-rtk-hangkiller.log}"
echo "[hang-killer] max_age=${MAX_AGE_S}s pid=$$ $(date '+%F %T')" >> "$LOG"
while true; do
  now=$(date +%s)
  for id in $(docker ps -q 2>/dev/null); do
    st=$(docker inspect -f '{{.State.StartedAt}}' "$id" 2>/dev/null)
    ep=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "${st%%.*}" +%s 2>/dev/null)
    [ -n "$ep" ] || continue
    age=$(( now - ep ))
    if [ "$age" -gt "$MAX_AGE_S" ]; then
      img=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null | sed -E 's@programbench-compiled/([^:]+):.*@\1@')
      echo "$(date '+%H:%M:%S') KILL hung $id ($img) age=${age}s" >> "$LOG"
      docker rm -f "$id" >/dev/null 2>&1
    fi
  done
  sleep 60
done
