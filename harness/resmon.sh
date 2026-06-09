#!/bin/bash
# Lightweight resource sampler for the re-eval. Logs every 30s:
# time, #containers, total container CPU%, VM mem used (MiB), host load1,
# host unused MiB, host compressor, cumulative swapouts.
# Stop: kill $(cat /tmp/codex-pilot-2-resmon.pid)
LOG=/tmp/codex-pilot-2-resmon.log
echo "ts cont cpu% vmMemMiB load1 hostUnusedMiB compressor swapouts" >> "$LOG"
while true; do
  ts=$(date '+%H:%M:%S')
  stats=$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' 2>/dev/null)
  ncont=$(printf '%s\n' "$stats" | grep -c .)
  totcpu=$(printf '%s\n' "$stats" | awk '{gsub(/%/,"",$1); s+=$1} END{printf "%.0f", s+0}')
  vmmem=$(printf '%s\n' "$stats" | awk '{v=$2; if(v ~ /GiB/){gsub(/GiB/,"",v); v=v*1024} else {gsub(/MiB/,"",v)}; s+=v+0} END{printf "%.0f", s+0}')
  load1=$(uptime | sed -E 's/.*averages?: //' | awk '{print $1}')
  pm=$(top -l 1 -n 0 2>/dev/null | grep PhysMem)
  unused=$(echo "$pm" | grep -oE '[0-9]+[MG] unused' | grep -oE '[0-9]+[MG]' | awk '{u=$1; if(index($1,"G")){gsub(/G/,"",u); u=u*1024}else{gsub(/M/,"",u)}; print u}')
  comp=$(echo "$pm" | grep -oE '[0-9]+G compressor' | grep -oE '[0-9]+G')
  swo=$(top -l 1 -n 0 2>/dev/null | grep -E '^VM:' | grep -oE '[0-9]+\([0-9]+\) swapouts' | head -1)
  echo "$ts $ncont $totcpu $vmmem $load1 $unused $comp $swo" >> "$LOG"
  sleep 30
done
