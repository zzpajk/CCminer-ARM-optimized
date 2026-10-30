#!/usr/bin/env bash
# phone-cpuwatch.sh [minutes] [widen|nowiden] - how often does Android take CPUs away from a miner?
# Runs the newest benchmark binary built by verus-ref-bench.sh (x2percorep-jt4, else x2percorep) on all CPUs
# and samples every 10 s: the foreground/top-app cpusets, the CPUs the miner is allowed, the CPU each miner
# thread last ran on, and the screen state (via root, if available). Changes are logged with timestamps;
# a status line with the miner's hashrate every 5 minutes. "widen" (default) first sets the foreground cpuset
# to all CPUs ONCE (root) and restores the original value at the end. Benchmark mode only, never a pool.
set -u
MIN="${1:-120}"; MODE="${2:-widen}"
case "$MIN" in ''|*[!0-9]*) echo "minutes must be a number"; exit 2;; esac
F=/dev/cpuset/foreground/cpus
SU=""
for s in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /data/adb/magisk/su; do [ -x "$s" ] && { SU=$s; break; }; done
BIN=$(ls -t "$HOME"/verus-runs/work-bench-*/bin/ccminer-x2percorep-jt4 2>/dev/null | head -1)
[ -n "$BIN" ] || BIN=$(ls -t "$HOME"/verus-runs/work-bench-*/bin/ccminer-x2percorep 2>/dev/null | head -1)
[ -x "${BIN:-}" ] || { echo "no benchmark binary found under ~/verus-runs (run a bench job first)"; exit 1; }
NCPU=$(grep -c ^processor /proc/cpuinfo); ALL=$(cat /sys/devices/system/cpu/present 2>/dev/null || echo "0-$((NCPU-1))")
ts() { date '+%F %T'; }
screen() { [ -n "$SU" ] || { echo "?"; return; }
	timeout 10 "$SU" -c "dumpsys power" </dev/null 2>/dev/null | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2; }
ORIG=$(cat "$F" 2>/dev/null)
echo "$(ts) binary $BIN"
echo "$(ts) cpus present $ALL; foreground=$ORIG top-app=$(cat /dev/cpuset/top-app/cpus 2>/dev/null) background=$(cat /dev/cpuset/background/cpus 2>/dev/null); su=${SU:-none}; screen=$(screen)"
if [ "$MODE" = widen ]; then
	[ -n "$SU" ] || { echo "widen needs root (Android su)"; exit 1; }
	timeout 15 "$SU" -c "echo $ALL > $F" </dev/null && echo "$(ts) foreground cpuset set ONCE to $(cat $F) (no repeat loop)"
fi
LOG="$HOME/verus-runs/cpuwatch-miner.log"
"$BIN" -a verus --benchmark -t "$NCPU" --no-color > "$LOG" 2>&1 < /dev/null &
MP=$!
cleanup() { kill "$MP" 2>/dev/null; wait "$MP" 2>/dev/null
	if [ "$MODE" = widen ] && [ -n "$ORIG" ]; then timeout 15 "$SU" -c "echo $ORIG > $F" </dev/null && echo "$(ts) foreground cpuset restored to $ORIG"; fi; }
trap cleanup EXIT
sleep 5
echo "$(ts) miner pid $MP, $NCPU threads; sampling every 10 s for $MIN min"
end=$(( $(date +%s) + MIN * 60 )); last=""; changes=0; narrow=0; samples=0; nextst=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$end" ] && kill -0 "$MP" 2>/dev/null; do
	fg=$(cat "$F" 2>/dev/null); al=$(grep -m1 Cpus_allowed_list /proc/$MP/status 2>/dev/null | awk '{print $2}')
	# CPU each thread last ran on (field 39 of /proc/<pid>/task/<tid>/stat), as a sorted list
	on=$(for t in /proc/$MP/task/*/stat; do awk '{print $39}' "$t" 2>/dev/null; done | sort -n | tr '\n' ',' | sed 's/,$//')
	nb=$(for t in /proc/$MP/task/*/status; do grep -m1 Cpus_allowed_list "$t" 2>/dev/null | awk '{print $2}'; done | sort | uniq -c | tr -s ' ' | tr '\n' ';')
	samples=$((samples + 1))
	[ "$al" != "$ALL" ] && narrow=$((narrow + 1))
	cur="foreground=$fg miner_allowed=$al"
	if [ "$cur" != "$last" ]; then
		[ -n "$last" ] && changes=$((changes + 1))
		echo "$(ts) CHANGE $cur | threads on cpus $on | per-thread allowed: $nb | screen=$(screen)"
		last=$cur
	fi
	if [ "$(date +%s)" -ge "$nextst" ]; then
		hr=$(grep -oE 'Total: [0-9.]+ [kMG]?H/s' "$LOG" 2>/dev/null | tail -1)
		echo "$(ts) status: $cur | threads on cpus $on | ${hr:-no total yet} | screen=$(screen)"
		nextst=$(( $(date +%s) + 300 ))
	fi
	sleep 10
done
echo "$(ts) done: $samples samples, $changes changes, miner had fewer than all CPUs in $narrow samples ($(( narrow * 100 / (samples ? samples : 1) ))%)"
echo "$(ts) miner hashrate lines (first/last):"; grep -E 'Total:' "$LOG" | sed -n '1p;$p'
