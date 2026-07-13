#!/bin/sh
# Appends one disk/RAM/CPU/load snapshot to a local rolling log so the
# dashboard's Server Health charts work the same way regardless of host
# provider (DigitalOcean, Hetzner, or anything added later) - no cloud
# vendor's own monitoring API is involved.
#
# Format per line: unix_ts,disk_pct,ram_pct,cpu_pct,load1
# Self-capped at MAX_LINES so this never grows unbounded.
set -eu

LOG=/opt/n8n/metrics.csv
MAX_LINES=2016 # 7 days at 5-minute intervals

disk=$(df / | awk 'NR==2{print $5}' | tr -d '%')
ram=$(free | awk '/^Mem:/{printf "%.0f", ($2-$7)/$2*100}')
load=$(awk '{print $1}' /proc/loadavg)

# CPU %: idle-delta over a 1s sample of /proc/stat (fields: user nice system idle iowait irq softirq)
read -r _ u1 n1 s1 i1 w1 q1 sq1 _ </proc/stat
sleep 1
read -r _ u2 n2 s2 i2 w2 q2 sq2 _ </proc/stat
total1=$((u1 + n1 + s1 + i1 + w1 + q1 + sq1))
total2=$((u2 + n2 + s2 + i2 + w2 + q2 + sq2))
idle_delta=$((i2 - i1))
total_delta=$((total2 - total1))
if [ "$total_delta" -gt 0 ]; then
  cpu=$((100 - (idle_delta * 100 / total_delta)))
else
  cpu=0
fi

mkdir -p "$(dirname "$LOG")"
echo "$(date +%s),$disk,$ram,$cpu,$load" >>"$LOG"
tail -n "$MAX_LINES" "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
