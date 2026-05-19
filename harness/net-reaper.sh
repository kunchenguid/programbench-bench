#!/usr/bin/env bash
# Network reaper for the sandbox harness.
#
# WHY: run.sh / run-codex.sh each create 2 Docker networks per task
# (pb-agent-net-* internal + pb-proxy-net-* bridge) and remove them in a
# cleanup trap. The trap's `docker network rm` occasionally fails (a lingering
# endpoint at teardown, or a race), leaking those networks. Over a long run -
# or two co-running batches - they accumulate and exhaust Docker's default
# address pool (~24-31 networks). Once full, the NEXT `docker network create`
# fails instantly with "all predefined address pools have been fully subnetted"
# and every new task false-fails in <1s. See
# memory:gotcha_docker-network-pool-exhaustion.
#
# This loop periodically reaps ORPHANED harness networks. Three guards keep it
# safe to run alongside live tasks:
#   1. SCOPED  - only names matching ^pb-(agent|proxy)-net- are considered;
#                never touches non-harness or predefined (bridge/host/none) nets.
#   2. UNUSED  - only networks with zero attached containers (an active task's
#                networks have agent/proxy/cleanroom attached -> skipped).
#   3. AGED    - only networks older than PB_NET_REAP_AGE_SEC. This is the
#                race guard: a sibling task that just created its network (and
#                hasn't attached a container in the ~1-2s before) is younger
#                than the gate and is never removed.
# A network must fail ALL THREE (orphaned harness net, old enough) to be reaped,
# so a genuinely-leaked net is reclaimed while in-flight tasks are untouched.
#
# Usage:  nohup ./harness/net-reaper.sh > /tmp/net-reaper.log 2>&1 &
#         echo $! > /tmp/net-reaper.pid
# Stop:   kill "$(cat /tmp/net-reaper.pid)"
#
# Tunables (env):
#   PB_NET_REAP_INTERVAL_SEC  (default 180) - sweep cadence
#   PB_NET_REAP_AGE_SEC       (default 600) - reap orphaned nets older than this;
#                             must exceed the create->attach gap (a few seconds)
#
# NOTE: uses BSD `date -j -u -f` (macOS host) to parse Docker's space-separated
# UTC .Created timestamp. On parse failure it SKIPS the network (conservative -
# never reaps something whose age it can't confirm).
set -u
INTERVAL="${PB_NET_REAP_INTERVAL_SEC:-180}"
AGE_SEC="${PB_NET_REAP_AGE_SEC:-600}"

reap_once() {
  local now net created epoch age containers reaped=0
  now="$(date +%s)"
  while IFS= read -r net; do
    [ -n "$net" ] || continue
    containers="$(docker network inspect "$net" -f '{{len .Containers}}' 2>/dev/null)" || continue
    [ "$containers" = "0" ] || continue                 # in-use -> keep
    created="$(docker network inspect "$net" -f '{{.Created}}' 2>/dev/null)"
    # Go's default time format (what the template renders) is space-separated
    # and UTC, e.g. "2026-05-30 03:55:40.0999 +0000 UTC". Trim to seconds and
    # parse as UTC (-u), else the local-tz assumption skews the age.
    created="${created%%.*}"   # -> "YYYY-MM-DD HH:MM:SS"
    epoch="$(date -j -u -f "%Y-%m-%d %H:%M:%S" "$created" +%s 2>/dev/null)" || epoch=""
    [ -n "$epoch" ] || continue                         # unparseable -> skip (conservative)
    age=$(( now - epoch ))
    [ "$age" -ge "$AGE_SEC" ] || continue               # too young -> race guard
    if docker network rm "$net" >/dev/null 2>&1; then
      reaped=$(( reaped + 1 ))
      echo "$(date '+%F %T') reaped $net (orphaned ${age}s)"
    fi
  done < <(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E '^pb-(agent|proxy)-net-')
  return 0
}

echo "$(date '+%F %T') net-reaper started (interval=${INTERVAL}s age_gate=${AGE_SEC}s)"
while true; do
  reap_once
  sleep "$INTERVAL"
done
