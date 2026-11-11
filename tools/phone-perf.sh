#!/usr/bin/env bash
# phone-perf.sh [seconds] [cpus] [mode] [sels] [miner options...]
# Hardware-counter profile of the Verus benchmark (never a pool), one miner thread pinned to one CPU at a time.
# Needs Android root (su) and simpleperf (part of Android: /system/bin or /system/xbin). Changes no settings.
#   seconds  length of each measurement (default 30); a run = 10 s warm-up + 2 stat passes + 1 record pass
#   cpus     "auto" (default: the first allowed CPU of every cluster) or a list such as 0,4
#   mode     stat | record | both (default both) | full (record, then every instruction of each function
#            holding >= 2% of the samples, with its share: long output)
#   sels     "default" (the miner's own per-core choice) or a list such as default,384,419: one run per value,
#            the numbers are passed as VERUS_SEL. "l1" forces VERUS_LANES=1 (single-nonce loop).
#            "sN" (s128, s1152) sets VERUS_SEL1=N: single-nonce cores through the lane code with one lane.
# Output per run: hashrate, counters per second and PER HASH (cycles, instructions, branch misses, cache
# misses), IPC, branch-miss rate; then where the cycles go: by symbol, and the hottest instructions of the
# ccminer binary with their disassembly (sample addresses can be one instruction late: counter skid).
set -u
SEC="${1:-30}"; CPUS="${2:-auto}"; MODE="${3:-both}"; SELS="${4:-default}"; shift $(( $# < 4 ? $# : 4 ))
case "$SEC" in ''|*[!0-9]*|0) echo "seconds must be a number"; exit 2;; esac
case "$MODE" in stat|record|both|full) ;; *) echo "mode must be stat, record, both or full"; exit 2;; esac
case "$CPUS" in auto) ;; *[!0-9,]*|'') echo "cpus must be auto or a list like 0,4"; exit 2;; esac
case "$SELS" in *[!a-z0-9,]*|'') echo "sels must be a list like default,384,l1"; exit 2;; esac
ts() { date '+%F %T'; }
SU=""
for s in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /data/adb/magisk/su; do [ -x "$s" ] && { SU=$s; break; }; done
[ -n "$SU" ] || { echo "needs Android root (su): hardware counters are closed to apps (perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null))"; exit 1; }
asroot() { timeout "$1" "$SU" -c "$2" </dev/null; }
for p in /proc/[0-9]*; do
	case "$(cat "$p/comm" 2>/dev/null)" in ccminer*) echo "another ccminer is running (pid ${p#/proc/}); stop it first"; exit 1;; esac
done
BIN=""; [ -x "$HOME/ccminer/ccminer-verus" ] && BIN="$HOME/ccminer/ccminer-verus"
[ -n "$BIN" ] || BIN=$(ls -t "$HOME"/verus-runs/work-bench-*/bin/ccminer-x2percorep-jt4 2>/dev/null | head -1)
[ -n "$BIN" ] || BIN=$(ls -t "$HOME"/verus-runs/work-bench-*/bin/ccminer-x2percorep 2>/dev/null | head -1)
[ -x "${BIN:-}" ] || { echo "no benchmark binary found (run termux-install or a bench job first)"; exit 1; }
SP=""
for s in /system/bin/simpleperf /system/xbin/simpleperf /apex/com.android.runtime/bin/simpleperf "$(command -v simpleperf 2>/dev/null)"; do
	[ -n "$s" ] && asroot 10 "[ -x $s ]" 2>/dev/null && { SP=$s; break; }; done
C=/sys/devices/system/cpu
echo "$(ts) binary $BIN ($(cd "$(dirname "$BIN")" && git log -1 --format=%h 2>/dev/null)); extra miner options: ${*:-none}"
echo "$(ts) kernel $(uname -r); perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null); su=$SU; simpleperf=${SP:-NOT FOUND}"
if [ -z "$SP" ]; then
	echo "simpleperf is not on this phone. Looked in /system/bin, /system/xbin, /apex/com.android.runtime/bin, PATH."
	echo "perf-like tools present: $(ls /system/bin /system/xbin 2>/dev/null | grep -iE 'perf|oprofile|strace' | tr '\n' ' ')"
	echo "PMU devices: $(ls /sys/bus/event_source/devices 2>/dev/null | tr '\n' ' ')"
	exit 3
fi
echo "$(ts) PMU devices: $(ls /sys/bus/event_source/devices 2>/dev/null | tr '\n' ' ')"
AVAIL=$(asroot 60 "$SP list hw cache" 2>&1)
echo "$(ts) supported hardware/cache events: $(echo "$AVAIL" | grep -E '^ +[A-Za-z]' | tr -s ' \n' ' ')"
pick() { local o="" e; for e in "$@"; do echo "$AVAIL" | grep -qE "^ +$e( |\$)" && o="$o,$e"; done; echo "${o#,}"; }
EV1=$(pick cpu-cycles instructions branch-instructions branch-misses cache-misses cache-references)
EV2=$(pick cpu-cycles L1-dcache-loads L1-dcache-load-misses L1-icache-load-misses dTLB-load-misses branch-loads branch-load-misses)
[ -n "$EV1" ] || { echo "no hardware events are supported by this kernel:"; echo "$AVAIL" | head -30; exit 4; }

# CPUs: the first allowed CPU of every cluster (clusters = distinct maximum clocks)
ALLOWED=$(grep -m1 Cpus_allowed_list /proc/self/status | awk '{print $2}' | tr ',' '\n' | awk -F- '{for (i = $1; i <= (NF > 1 ? $2 : $1); i++) print i}')
if [ "$CPUS" = auto ]; then
	CPUS=$(for c in $ALLOWED; do echo "$(cat $C/cpu$c/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0) $c"; done | sort -n | awk '!seen[$1]++ {print $2}' | tr '\n' ',' | sed 's/,$//')
fi
echo "$(ts) allowed cpus: $(echo $ALLOWED | tr ' ' ','); measuring cpus $CPUS, VERUS_SEL $SELS, $SEC s per pass, mode $MODE"
awk '/^processor/{p=$3} /^CPU implementer/{i=$4} /^CPU part/{print "  cpu" p ": " i ":" $4}' /proc/cpuinfo | tr '\n' ' '; echo

TMPD="$HOME/verus-runs/perf"; mkdir -p "$TMPD"
DATA=/data/local/tmp/verus-perf-$$.data
DIS="$TMPD/disasm.txt"; DISOK=0
MP=""
cleanup() { [ -n "$MP" ] && kill "$MP" 2>/dev/null; asroot 15 "rm -f $DATA" 2>/dev/null; rm -f "$DIS"; }
trap cleanup EXIT

rate_hs() { # miner log -> mean H/s of the "Total:" lines after the first two
	grep -oE 'Total: [0-9.]+ [kMG]?H/s' "$1" | awk 'NR > 2 {v = $2; u = $3; if (u ~ /^k/) v *= 1e3; else if (u ~ /^M/) v *= 1e6; else if (u ~ /^G/) v *= 1e9; s += v; n++} END {if (n) printf "%.0f", s / n; else print 0}'
}
stat_pass() { # title events
	local out; out=$(asroot $((SEC + 60)) "$SP stat -e $2 -p $MP --duration $SEC" 2>&1)
	local hs; hs=$(rate_hs "$LOG")
	echo "--- $1 (hashrate so far $(awk -v h="$hs" 'BEGIN {printf "%.1f kH/s", h / 1e3}'))"
	echo "$out" | awk -v hs="$hs" '
		/Total test time/ { for (i = 1; i <= NF; i++) if ($i + 0 > 0) { dur = $i + 0; break } }
		{ c = $1; gsub(/,/, "", c) }
		c ~ /^[0-9]+$/ && $2 ~ /^[A-Za-z]/ { n++; name[n] = $2; cnt[$2] = c + 0 }
		END {
			if (!n) { print "  (could not read the counters)"; exit }
			if (dur <= 0) dur = 1
			printf "  %-26s %16s %14s %12s\n", "event", "count", "per second", "per hash"
			for (i = 1; i <= n; i++) { e = name[i]; printf "  %-26s %16.0f %14.0f %12s\n", e, cnt[e], cnt[e] / dur, (hs > 0 ? sprintf("%.2f", cnt[e] / dur / hs) : "n/a") }
			if (cnt["cpu-cycles"] > 0 && cnt["instructions"] > 0) printf "  IPC %.2f, effective clock %.0f MHz\n", cnt["instructions"] / cnt["cpu-cycles"], cnt["cpu-cycles"] / dur / 1e6
			if (cnt["branch-instructions"] > 0) printf "  branch-miss rate %.2f%% of branches\n", 100 * cnt["branch-misses"] / cnt["branch-instructions"]
			else if (cnt["branch-loads"] > 0) printf "  branch-miss rate %.2f%% of branches\n", 100 * cnt["branch-load-misses"] / cnt["branch-loads"]
			if (cnt["L1-dcache-loads"] > 0) printf "  L1d miss rate %.3f%% of loads\n", 100 * cnt["L1-dcache-load-misses"] / cnt["L1-dcache-loads"]
		}'
	echo "$out" | grep -iE 'error|fail|not supported|denied' | head -5
}
record_pass() {
	echo "--- where the cycles go ($SEC s, 2000 samples/s)"
	asroot $((SEC + 60)) "$SP record -e cpu-cycles -f 2000 -p $MP --duration $SEC -o $DATA" 2>&1 | grep -vE '^$' | tail -4
	echo "by symbol:"
	asroot 120 "$SP report -i $DATA --sort dso,symbol" 2>&1 | grep -E '%' | sed -n 1,12p | cut -c1-170
	local hot; hot=$(asroot 120 "$SP report -i $DATA --sort dso,vaddr_in_file" 2>&1 | grep -E '%' | grep ccminer | sed -n "1,$([ "$MODE" = full ] && echo 20000 || echo 80)p")
	if [ -z "$hot" ]; then echo "(this simpleperf has no per-address report)"; return; fi
	if [ $DISOK = 0 ]; then
		local od; od=$(command -v llvm-objdump || command -v objdump)
		[ -n "$od" ] && "$od" -d --no-show-raw-insn "$BIN" > "$DIS" 2>/dev/null && [ -s "$DIS" ] && DISOK=1
	fi
	if [ $DISOK = 1 ] && [ "$MODE" = full ]; then
		echo "every instruction of the functions with >= 2% of the samples (% of all samples):"
		echo "$hot" | awk '{p = $1; a = $NF; sub(/^0x/, "", a); print "H", tolower(a), p}' | cat - "$DIS" | awk '
			$1 == "H" { pc[$2] = $3 + 0; next }
			/^[0-9a-f]+ <.*>:$/ { nf++; fname[nf] = $2; first[nf] = n + 1; next }
			nf && /^ *[0-9a-f]+:/ { a = $1; sub(/:$/, "", a); sub(/^0+/, "", a); n++; line[n] = $0; fl[n] = nf; if (a in pc) { h[n] = pc[a]; tot[nf] += pc[a] } }
			END { for (i = 1; i <= n; i++) if (tot[fl[i]] >= 2) {
					if (i == first[fl[i]]) printf "== %s: %.2f%%\n", fname[fl[i]], tot[fl[i]]
					s = line[i]; gsub(/[ \t]+/, " ", s); sub(/ <[^>]*>$/, "", s)
					printf "%s%s\n", (i in h ? sprintf("%5.2f", h[i]) : "     "), s } }' | cut -c1-110
		asroot 15 "rm -f $DATA" 2>/dev/null
		return
	fi
	echo "hottest instructions (% of all samples; 2 lines of context; '....' = gap):"
	if [ $DISOK = 1 ]; then
		echo "$hot" | awk '{p = $1; a = $NF; sub(/^0x/, "", a); print "H", tolower(a), p}' | cat - "$DIS" | awk '
			$1 == "H" { pc[$2] = $3; next }
			/^[0-9a-f]+ <.*>:$/ { fn = $2; next }
			{ a = $1; sub(/:$/, "", a); sub(/^0+/, "", a); n++; line[n] = $0; f[n] = fn; if (a in pc) { hotl[n] = pc[a]; for (k = n - 2; k <= n + 2; k++) want[k] = 1 } }
			END { last = 0; lf = ""
				for (i = 1; i <= n; i++) if (want[i]) {
					if (f[i] != lf) { print "  in " f[i]; lf = f[i] } else if (last && i != last + 1) print "  ...."
					printf "  %7s %s\n", (i in hotl ? hotl[i] : ""), line[i]; last = i } }' | cut -c1-150 | head -400
	else
		echo "(no objdump: addresses only)"; echo "$hot" | head -60
	fi
	asroot 15 "rm -f $DATA" 2>/dev/null
}

for cpu in $(echo "$CPUS" | tr ',' ' '); do
	echo "$ALLOWED" | grep -qx "$cpu" || { echo "$(ts) cpu$cpu is not in the allowed set, skipped"; continue; }
	for sel in $(echo "$SELS" | tr ',' ' '); do
		LOG="$TMPD/miner-cpu$cpu-$sel.log"
		( unset VERUS_SEL VERUS_LANES VERUS_SEL1 VERUS_PRE1
		  case "$sel" in default) ;; l1) export VERUS_LANES=1;; s[0-9]*) export VERUS_SEL1="${sel#s}";; *) export VERUS_SEL="$sel";; esac
		  exec "$BIN" -a verus --benchmark -t 1 --cpu-affinity "$(printf '0x%x' $((1 << cpu)))" --no-color "$@" ) > "$LOG" 2>&1 < /dev/null &
		MP=$!
		sleep 10
		kill -0 "$MP" 2>/dev/null || { echo "$(ts) miner did not start on cpu$cpu:"; tail -5 "$LOG"; MP=""; continue; }
		echo
		echo "===== $(ts) cpu$cpu, VERUS_SEL=$sel: $(grep -m1 -oE 'Verus thread.*' "$LOG"); clock $(( $(cat $C/cpu$cpu/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000 )) of $(( $(cat $C/cpu$cpu/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0) / 1000 )) MHz; threads on cpus $(for t in /proc/$MP/task/*/stat; do awk '{print $39}' "$t" 2>/dev/null; done | sort -n | tr '\n' ' ')"
		case "$MODE" in stat|both)
			stat_pass "counters, pass 1" "$EV1"
			[ -n "$EV2" ] && [ "$EV2" != cpu-cycles ] && stat_pass "counters, pass 2 (cache / TLB)" "$EV2";; esac
		case "$MODE" in record|both|full) record_pass;; esac
		echo "--- $(ts) final hashrate $(awk -v h="$(rate_hs "$LOG")" 'BEGIN {printf "%.1f kH/s", h / 1e3}'), clock now $(( $(cat $C/cpu$cpu/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000 )) MHz"
		kill "$MP" 2>/dev/null; wait "$MP" 2>/dev/null; MP=""
		sleep 3
	done
done
echo
echo "$(ts) done"
