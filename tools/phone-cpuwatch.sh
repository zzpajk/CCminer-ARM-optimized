#!/usr/bin/env bash
# phone-cpuwatch.sh [minutes] [widen|nowiden] [status-seconds] [miner options...]
# How often does Android take CPUs away from a miner, and how fast / hot / throttled is the phone under load?
# Runs a benchmark (never a pool) on all CPUs: ~/ccminer/ccminer-verus (termux-install.sh) if present, else
# the newest binary built by verus-ref-bench.sh. Samples every 10 s: the foreground/top-app cpusets, the CPUs
# the miner is allowed, the CPU each miner thread last ran on, the screen state (via root, if available).
# Changes are logged with timestamps; a status line every status-seconds (default 300) with the hashrate,
# each CPU's current clock (MHz), the clock caps below the hardware maximum, and the CPU temperatures.
# "widen" (default) first sets the foreground cpuset to all CPUs ONCE (root) and restores it at the end.
# MODE may be "widen,cap1794" / "nowiden,cap1794": also cap the fast cores' clock (root; restored at the end).
# Extra miner options (e.g. --cpu-priority 1) are passed through. Refuses to run while another ccminer runs.
# Options of the form VERUS_NAME=value (VERUS_SEL, VERUS_SEL1, VERUS_LANES, VERUS_PRE1) are set in the miner's
# environment instead (variant comparisons with one binary).
set -u
MIN="${1:-120}"; MODE="${2:-widen}"; CAPMHZ=""
# MODE may carry ",capNNNN": cap the fast cores (all CPUs above the slowest cluster) at NNNN MHz (root)
case "$MODE" in *,cap*) CAPMHZ="${MODE##*,cap}"; MODE="${MODE%%,*}";; esac
case "$CAPMHZ" in *[!0-9]*) echo "bad cap value $CAPMHZ"; exit 2;; esac
 STS="${3:-300}"; shift $(( $# < 3 ? $# : 3 ))
case "$STS" in ''|*[!0-9]*|0) STS=300;; esac
case "$MIN" in ''|*[!0-9]*) echo "minutes must be a number"; exit 2;; esac
MOPTS=()
for o in "$@"; do
	case "$o" in
		VERUS_SEL=*|VERUS_SEL1=*|VERUS_LANES=*|VERUS_PRE1=*)
			case "${o#*=}" in ''|*[!0-9]*) echo "bad value in $o"; exit 2;; esac; export "$o";;
		*) MOPTS+=("$o");;
	esac
done
set -- ${MOPTS[@]+"${MOPTS[@]}"}
F=/dev/cpuset/foreground/cpus
SU=""
for s in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /data/adb/magisk/su; do [ -x "$s" ] && { SU=$s; break; }; done
for p in /proc/[0-9]*; do
	case "$(cat "$p/comm" 2>/dev/null)" in ccminer*) echo "another ccminer is running (pid ${p#/proc/}: $(tr '\0' ' ' < "$p/cmdline" | cut -c1-80)); stop it first"; exit 1;; esac
done
BIN=""; [ -x "$HOME/ccminer/ccminer-verus" ] && BIN="$HOME/ccminer/ccminer-verus"
[ -n "$BIN" ] || BIN=$(ls -t "$HOME"/verus-runs/work-bench-*/bin/ccminer-x2percorep-jt4 2>/dev/null | head -1)
[ -n "$BIN" ] || BIN=$(ls -t "$HOME"/verus-runs/work-bench-*/bin/ccminer-x2percorep 2>/dev/null | head -1)
[ -x "${BIN:-}" ] || { echo "no benchmark binary found under ~/verus-runs (run a bench job first)"; exit 1; }
NCPU=$(grep -c ^processor /proc/cpuinfo); ALL=$(cat /sys/devices/system/cpu/present 2>/dev/null || echo "0-$((NCPU-1))")
ts() { date '+%F %T'; }
C=/sys/devices/system/cpu
freqs() { local o="" c; for c in $C/cpu[0-9]*; do o="$o $(( $(cat $c/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000 ))"; done; echo "${o# }"; }
caps() { local o="" c mx sm; for c in $C/cpu[0-9]*; do mx=$(cat $c/cpufreq/cpuinfo_max_freq 2>/dev/null); sm=$(cat $c/cpufreq/scaling_max_freq 2>/dev/null)
	[ -n "$mx" ] && [ -n "$sm" ] && [ "$sm" -lt "$mx" ] && o="$o ${c##*/}:$((sm/1000))/$((mx/1000))"; done; echo "${o# }"; }
temps() { local o="" z t v n=0; for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type 2>/dev/null); v=$(cat $z/temp 2>/dev/null)
	case "$t" in *[Cc][Pp][Uu]*|*[Bb][Ii][Gg]*|*[Ll][Ii][Tt][Tt][Ll][Ee]*|*[Mm][Ii][Dd]*|*AP*|*ap_*|*soc*|*SOC*) ;; *) continue;; esac
	[ -n "$v" ] || continue; [ "$v" -gt 1000 ] && v=$((v/1000)); o="$o $t=${v}C"; n=$((n+1)); [ $n -ge 6 ] && break; done; echo "${o# }"; }
screen() { [ -n "$SU" ] || { echo "?"; return; }
	timeout 10 "$SU" -c "dumpsys power" </dev/null 2>/dev/null | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2; }
ORIG=$(cat "$F" 2>/dev/null)
echo "$(ts) binary $BIN; extra options: ${*:-none}"
echo "$(ts) idle: MHz $(freqs) | caps $(c=$(caps); echo "${c:-none}") | $(temps)"
echo "$(ts) cpus present $ALL; foreground=$ORIG top-app=$(cat /dev/cpuset/top-app/cpus 2>/dev/null) background=$(cat /dev/cpuset/background/cpus 2>/dev/null); su=${SU:-none}; screen=$(screen)"
if [ "$MODE" = widen ]; then
	[ -n "$SU" ] || { echo "widen needs root (Android su)"; exit 1; }
	timeout 15 "$SU" -c "echo $ALL > $F" </dev/null && echo "$(ts) foreground cpuset set ONCE to $(cat $F) (no repeat loop)"
fi
CAPPED=""
if [ -n "$CAPMHZ" ]; then
	[ -n "$SU" ] || { echo "cap needs root (Android su)"; exit 1; }
	lo=$(cat $C/cpu[0-9]*/cpufreq/cpuinfo_max_freq 2>/dev/null | sort -n | head -1)
	for c in $C/cpu[0-9]*; do
		mx=$(cat $c/cpufreq/cpuinfo_max_freq 2>/dev/null); [ -n "$mx" ] && [ "$mx" -gt "$lo" ] || continue
		# largest available frequency <= the cap
		f=$(tr ' ' '\n' < $c/cpufreq/scaling_available_frequencies 2>/dev/null | awk -v t=$((CAPMHZ*1000)) '$1 <= t && $1 > b {b = $1} END {print b+0}')
		[ "$f" -gt 0 ] || f=$((CAPMHZ*1000))
		timeout 15 "$SU" -c "echo $f > $c/cpufreq/scaling_max_freq" </dev/null && CAPPED="$CAPPED ${c##*/}"
		CAPF=$f
	done
	echo "$(ts) fast cores capped at $((CAPF/1000)) MHz:$CAPPED (read back: $(for c in $CAPPED; do printf '%s ' $(( $(cat $C/$c/cpufreq/scaling_max_freq) / 1000 )); done))"
fi
LOG="$HOME/verus-runs/cpuwatch-miner.log"
echo "$(date '+%F %T') variant environment: $(env | grep -E '^VERUS_(SEL|SEL1|LANES|PRE1)=' | tr '\n' ' ')(empty = built-in defaults)"
"$BIN" -a verus --benchmark -t "$NCPU" --no-color "$@" > "$LOG" 2>&1 < /dev/null &
MP=$!
cleanup() { kill "$MP" 2>/dev/null; wait "$MP" 2>/dev/null
	if [ "$MODE" = widen ] && [ -n "$ORIG" ]; then timeout 15 "$SU" -c "echo $ORIG > $F" </dev/null && echo "$(ts) foreground cpuset restored to $ORIG"; fi
	for c in $CAPPED; do timeout 15 "$SU" -c "cat $C/$c/cpufreq/cpuinfo_max_freq > $C/$c/cpufreq/scaling_max_freq" </dev/null; done
	[ -n "$CAPPED" ] && echo "$(ts) clock cap removed:$CAPPED (now $(for c in $CAPPED; do printf '%s ' $(( $(cat $C/$c/cpufreq/scaling_max_freq) / 1000 )); done)MHz)"; }
trap cleanup EXIT
sleep 5
echo "$(ts) miner pid $MP, $NCPU threads; sampling every 10 s for $MIN min, status every $STS s"
t_start=$(date +%s); sum=0; cnt=0
end=$(( $(date +%s) + MIN * 60 )); last=""; changes=0; narrow=0; samples=0; nextst=$(( $(date +%s) + STS ))
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
		if [ $(( $(date +%s) - t_start )) -ge 300 ] && [ -n "$hr" ]; then
			sum=$(awk -v a="$sum" -v b="$(echo "$hr" | awk '{print $2}')" 'BEGIN {print a + b}'); cnt=$((cnt + 1)); fi
		echo "$(ts) status: ${hr:-no total yet} | MHz $(freqs) | caps $(caps | sed 's/^$/none/') | $(temps) | $cur | threads on $on"
		nextst=$(( $(date +%s) + STS ))
	fi
	sleep 10
done
echo "$(ts) done: $samples samples, $changes changes, miner had fewer than all CPUs in $narrow samples ($(( narrow * 100 / (samples ? samples : 1) ))%)"
echo "$(ts) average hashrate after the first 5 min: $(awk -v s="$sum" -v k="$cnt" 'BEGIN {if (k > 0) printf "%.1f kH/s over %d status lines", s / k, k; else print "n/a"}')"
echo "$(ts) miner hashrate lines (first/last):"; grep -E 'Total:' "$LOG" | sed -n '1p;$p'
echo "$(ts) variant per thread:"; grep -oE 'Verus thread [0-9]+.*' "$LOG" | sort -t' ' -k3,3n | uniq | head -16
