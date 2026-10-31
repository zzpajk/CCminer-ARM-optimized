#!/usr/bin/env bash
# phone-load.sh [seconds] - what is the phone's CPU actually doing while "idle"? Read-only.
# Prints the load average, the real busy % of every CPU measured over [seconds] (default 10) from /proc/stat,
# the number of running and blocked (D-state) tasks, the D-state tasks by name (they count in the load
# average without using CPU), and the processes using the most CPU. Uses Android root (su) when available,
# because without it Android hides other apps' processes from Termux.
set -u
SEC="${1:-10}"
case "$SEC" in ''|*[!0-9]*|0) SEC=10;; esac
SU=""
for s in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /data/adb/magisk/su; do [ -x "$s" ] && { SU=$s; break; }; done
asroot() { if [ -n "$SU" ]; then timeout 30 "$SU" -c "$1" </dev/null 2>/dev/null; else sh -c "$1" 2>/dev/null; fi; }

echo "$(date '+%F %T') load: $(cut -d' ' -f1-3 /proc/loadavg)  su: ${SU:-none, so processes of other apps are hidden}"
grep -E '^procs_(running|blocked)' /proc/stat | tr '\n' ' '; echo

snap() { grep -E '^cpu[0-9]+ ' /proc/stat; }
a=$(snap); sleep "$SEC"; b=$(snap)
echo "CPU busy % over ${SEC} s (100 = fully used):"
paste <(echo "$a") <(echo "$b") | awk '{
	n = (NF) / 2; ia = $5 + $6; ib = $(n+5) + $(n+6); ta = 0; tb = 0
	for (i = 2; i <= n; i++) ta += $i; for (i = n + 2; i <= NF; i++) tb += $i
	dt = tb - ta; di = ib - ia; printf "  %s %5.1f%%\n", $1, (dt > 0 ? 100 * (dt - di) / dt : 0) }'
for c in /sys/devices/system/cpu/cpu[0-9]*; do printf '%s ' "$(( $(cat $c/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000 ))"; done | sed 's/^/clocks MHz: /'; echo

echo "tasks in D state (count in the load average, use no CPU):"
asroot 'for p in /proc/[0-9]*/task/[0-9]*; do s=$(cut -d" " -f3 $p/stat 2>/dev/null); [ "$s" = D ] && cat $p/comm 2>/dev/null; done' | sort | uniq -c | sort -rn | head -15 | sed 's/^/  /'

echo "top CPU users:"
asroot 'top -b -n 1 -m 15 2>/dev/null || top -n 1 -m 15' | sed -n '1,25p' | cut -c1-150
