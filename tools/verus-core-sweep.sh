#!/usr/bin/env bash
# verus-core-sweep.sh v1.4: fill in the x2percore table for a new phone in one run.
#
# For every CPU core type of this device (grouped by "CPU implementer:part" from /proc/cpuinfo) it runs the
# miner pinned to ONE core of that type, once per hashing path, and reports which path is fastest:
#   plain  single-nonce loop (what in-order cores use)       VERUS_LANES=1
#   plainp the same loop, variant "pristine" (no key journal) VERUS_LANES=1, x2percore+pristine binary
#   x2     two nonces in lockstep                           VERUS_LANES=2 VERUS_SEL=0
#   sel    x2 + branch-free choice in case 0x14             VERUS_LANES=2 VERUS_SEL=1
#   sel2   x2 + branch-free choice in cases 0x14 and 0x18   VERUS_LANES=2 VERUS_SEL=3
#   fuse   x2 with one 64-way dispatch on the pair of cases VERUS_LANES=2 VERUS_SEL=8
#   fuse2  fuse + sel2                                       VERUS_LANES=2 VERUS_SEL=11
#   light  sel2 + cases 0/4/8/0x1c merged (5 jump targets)    VERUS_LANES=2 VERUS_SEL=19
#   selc   sel2 + branch-free case 0x0c                       VERUS_LANES=2 VERUS_SEL=35
#   lightc sel2 + both                                        VERUS_LANES=2 VERUS_SEL=51
#   x2light / x2selc / x2lightc  the same on top of plain x2  VERUS_SEL=16 / 32 / 48
#   bt / sel2bt / x2bt  selc / sel2 / x2 with branch-table dispatch (no table load)  VERUS_SEL=99 / 67 / 64
# (-P chooses which two-nonce paths run; default: x2 sel sel2 fuse fuse2)
# and compares the winner with what x2percore picks by default for that core type today.
# Optionally (-a) it also runs all cores: x2percore default vs plain everywhere.
#
# It builds two binaries from the fork's `variants` branch, x2percore and x2percore+pristine, unless -b/-p
# give them (-b alone: the pristine column is skipped).
# Needs: clang, make, git, libcurl/jansson/ssl dev packages (the same ones verus-ref-bench.sh installs).
# Runs in UserLAnd/Ubuntu or Termux. Benchmark mode only: it never connects to a pool.
#
# Usage: bash verus-core-sweep.sh [-d secs] [-r rounds] [-c cooldown] [-b bin] [-p bin] [-B branch] [-P paths] [-a] [-A]
#   -d  seconds per run (default 20)        -r  rounds, order reversed every other round (default 2)
#   -c  cooldown seconds between runs (8)   -b  x2percore binary to use instead of building
#   -p  x2percore+pristine binary
#   -B  branch or commit to build (variants)
#   -a  also run the all-core comparison    -A  also test the x2 paths on in-order cores (normally skipped)
#   -P  two-nonce paths to run, e.g. -P "sel2 light selc lightc"
set -u
DUR=20; ROUNDS=2; COOL=8; BIN=""; BINP=""; BRANCH="variants"; ALLCORE=0; ALLINORDER=0; XPATHS="x2 sel sel2 fuse fuse2"
REPO="https://github.com/zzpajk/CCminer-ARM-optimized.git"
while getopts "d:r:c:b:p:B:P:aAh" o; do
	case "$o" in d) DUR=$OPTARG;; r) ROUNDS=$OPTARG;; c) COOL=$OPTARG;; b) BIN=$OPTARG;; p) BINP=$OPTARG;; B) BRANCH=$OPTARG;; P) XPATHS=$OPTARG;;
		a) ALLCORE=1;; A) ALLINORDER=1;; *) sed -n '2,34p' "$0"; exit 0;; esac
done
WORK="${VERUS_SWEEP_DIR:-$HOME/verus-sweep}"
mkdir -p "$WORK"; cd "$WORK" || exit 1
LOG="$WORK/sweep-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$LOG") 2>&1

say() { printf '%s\n' "$*"; }

# ---------- core types ----------
partname() { # impl part
	case "$1:$2" in
	0x41:0xd03) echo A53;; 0x41:0xd04) echo A35;; 0x41:0xd05) echo A55;; 0x41:0xd07) echo A57;; 0x41:0xd08) echo A72;;
	0x41:0xd09) echo A73;; 0x41:0xd0a) echo A75;; 0x41:0xd0b) echo A76;; 0x41:0xd0d) echo A77;; 0x41:0xd41) echo A78;;
	0x41:0xd44) echo X1;; 0x41:0xd46) echo A510;; 0x41:0xd47) echo A710;; 0x41:0xd48) echo X2;; 0x41:0xd4d) echo A715;;
	0x41:0xd4e) echo X3;; 0x41:0xd80) echo A520;; 0x41:0xd81) echo A720;; 0x41:0xd82) echo X4;; 0x41:0xd85) echo X925;;
	0x41:0xd87) echo A725;;
	0x53:0x001) echo Mongoose-M1/M2;; 0x53:0x002) echo Mongoose-M3;; 0x53:0x003) echo Mongoose-M4;; 0x53:0x004) echo Mongoose-M5;;
	0x51:0x800) echo Kryo-Gold-2xx;; 0x51:0x801) echo Kryo-Silver-2xx;; 0x51:0x802) echo Kryo-385-Gold;; 0x51:0x803) echo Kryo-385-Silver;;
	0x51:0x804) echo Kryo-485-Gold;; 0x51:0x805) echo Kryo-485-Silver;;
	*) echo unknown;; esac
}
# mirrors verus_lanes_for_this_core / verus_sel_for_cpu in verus/verusscan.cpp
inorder() { case "$1:$2" in 0x41:0xd02|0x41:0xd03|0x41:0xd04|0x41:0xd05|0x41:0xd46|0x41:0xd80|0x51:0x801|0x51:0x803|0x51:0x805) return 0;; esac; return 1; }
default_path() {
	if inorder "$1" "$2"; then echo plain
	elif [ "$1" = 0x53 ]; then case "$2" in 0x001) echo x2;; *) echo selc;; esac
	elif [ "$1:$2" = 0x41:0xd09 ]; then echo x2
	elif [ "$1:$2" = 0x41:0xd0a ]; then echo sel2
	elif [ "$1:$2" = 0x41:0xd0b ]; then echo bt
	else echo selc; fi
}

declare -A TYPE_CPUS TYPE_MAXF
TYPES=()
cpu=-1; impl=""; part=""
while IFS= read -r line; do
	case "$line" in
	processor*) cpu=${line##*: }; impl=""; part="";;
	"CPU implementer"*) impl=${line##*: };;
	"CPU part"*) part=${line##*: }
		if [ -n "$impl" ] && [ "$cpu" -ge 0 ]; then
			k="$impl:$part"
			[ -z "${TYPE_CPUS[$k]+x}" ] && { TYPES+=("$k"); TYPE_CPUS[$k]=""; }
			TYPE_CPUS[$k]="${TYPE_CPUS[$k]} $cpu"
		fi;;
	esac
done < "${VERUS_CPUINFO:-/proc/cpuinfo}"
NCPU=$(grep -c "^processor" "${VERUS_CPUINFO:-/proc/cpuinfo}")
[ ${#TYPES[@]} -gt 0 ] || { say "Could not read CPU implementer/part from /proc/cpuinfo"; exit 1; }

model=$(getprop ro.product.model 2>/dev/null); soc=$(getprop ro.hardware.chipname 2>/dev/null || true)
[ -z "$model" ] && model=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
[ -z "$soc" ] && soc=$(grep -m1 '^Hardware' "${VERUS_CPUINFO:-/proc/cpuinfo}" | sed 's/.*: //')
say "verus-core-sweep v1.3  $(date '+%Y-%m-%d %H:%M')"
say "Device: ${model:-?}  SoC: ${soc:-?}  CPUs: $NCPU  kernel $(uname -r)"
say "Features: $(grep -m1 '^Features' "${VERUS_CPUINFO:-/proc/cpuinfo}" | sed 's/.*: //')"
for k in "${TYPES[@]}"; do
	set -- ${TYPE_CPUS[$k]}; first=$1
	f=$(cat /sys/devices/system/cpu/cpu$first/cpufreq/cpuinfo_max_freq 2>/dev/null); f=${f:+$((f / 1000)) MHz}
	TYPE_MAXF[$k]=${f:-?}
	inorder ${k%:*} ${k#*:} && io="in-order" || io="out-of-order"
	say "  type $k $(partname ${k%:*} ${k#*:}): cpus${TYPE_CPUS[$k]}  max ${TYPE_MAXF[$k]}  $io  x2percore default: $(default_path ${k%:*} ${k#*:})"
done

# ---------- binary ----------
if [ -z "$BIN" ]; then
	say ""; say "Building x2percore and x2percore+pristine from $REPO ($BRANCH) ..."
	if [ -d src/.git ]; then git -C src fetch -q origin "$BRANCH" && git -C src checkout -q FETCH_HEAD
	else git clone -q -b "$BRANCH" "$REPO" src 2>/dev/null || { git clone -q "$REPO" src && git -C src checkout -q "$BRANCH"; }; fi
	[ -d src/.git ] || { say "clone failed"; exit 1; }
	rev=$(git -C src rev-parse --short HEAD)
	build() { # name cppflags
		rm -rf "build-$1"; mkdir "build-$1"
		( cd src && git ls-files -z | grep -zv '\.o$' | xargs -0 cp --parents -t "../build-$1" )
		( cd "build-$1"
		  find . -name '*.o' -delete; rm -f ccminer *.opt.yaml config.status
		  # older clang (e.g. clang 10 on Ubuntu 20.04) does not know -ffinite-loops
		  echo 'int main(){return 0;}' > fl.c
		  clang -ffinite-loops -c fl.c -o fl.o 2>/dev/null || sed -i 's/-ffinite-loops //' configure.sh
		  sh ./configure.sh > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
		  make -j"$NCPU" CPPFLAGS="$2" > make.log 2>&1 || { grep -E 'error' make.log | head -20; exit 1; } ) || exit 1
		cp "build-$1/ccminer" "$WORK/ccminer-$1-$rev"
		say "Built $WORK/ccminer-$1-$rev"
	}
	build x2percore "-DVERUS_X2 -DVERUS_AUTO -DVERUS_PERCORE"
	build x2percorep "-DVERUS_X2 -DVERUS_AUTO -DVERUS_PERCORE -DVERUS_PRISTINE"
	BIN="$WORK/ccminer-x2percore-$rev"; BINP="$WORK/ccminer-x2percorep-$rev"
fi
[ -x "$BIN" ] || { say "No binary at $BIN"; exit 1; }
say "Binary: $BIN  ($("$BIN" --version 2>&1 | grep -o 'Verus variant: .*' | head -1))"
if [ -n "$BINP" ]; then
	[ -x "$BINP" ] || { say "No binary at $BINP"; exit 1; }
	say "Binary: $BINP  ($("$BINP" --version 2>&1 | grep -o 'Verus variant: .*' | head -1))"
fi

# ---------- runs ----------
# run NAME MASK THREADS -> prints H/s (time average is the miner's own final number)
run() {
	local name=$1 mask=$2 thr=$3 envs out hs path bin=$BIN
	case "$name" in plain) envs="VERUS_LANES=1";; plainp) envs="VERUS_LANES=1"; bin=$BINP;; x2) envs="VERUS_LANES=2 VERUS_SEL=0";; sel) envs="VERUS_LANES=2 VERUS_SEL=1";;
		sel2) envs="VERUS_LANES=2 VERUS_SEL=3";; fuse) envs="VERUS_LANES=2 VERUS_SEL=8";; fuse2) envs="VERUS_LANES=2 VERUS_SEL=11";;
		light) envs="VERUS_LANES=2 VERUS_SEL=19";; selc) envs="VERUS_LANES=2 VERUS_SEL=35";; lightc) envs="VERUS_LANES=2 VERUS_SEL=51";;
		bt) envs="VERUS_LANES=2 VERUS_SEL=99";; sel2bt) envs="VERUS_LANES=2 VERUS_SEL=67";; x2bt) envs="VERUS_LANES=2 VERUS_SEL=64";;
		x2light) envs="VERUS_LANES=2 VERUS_SEL=16";; x2selc) envs="VERUS_LANES=2 VERUS_SEL=32";; x2lightc) envs="VERUS_LANES=2 VERUS_SEL=48";;
		*) echo "0|unknown path $name"; return;;
		default) envs="";; esac
	local aff=""; [ "$mask" != none ] && aff="--cpu-affinity $mask"   # none: miner's own pinning (thread i on core i)
	out=$(env $envs "$bin" -a verus --benchmark -t "$thr" $aff --time-limit "$DUR" --no-color 2>&1)
	hs=$(printf '%s\n' "$out" | grep -E '^[0-9]+$' | tail -1)
	path=$(printf '%s\n' "$out" | grep -o 'cpu [0-9]*: [0-9] nonce(s) per step.*' | sed 's/ nonce(s) per step/ lane(s)/' | sort -u | head -3 | tr '\n' ';')
	echo "${hs:-0}|$path"
}
hexmask() { local m=0 c; for c in "$@"; do m=$((m | (1 << c))); done; printf '0x%x' "$m"; }

declare -A SUM CNT PATHSEEN
total=0
PL="plain"; [ -n "$BINP" ] && PL="plain plainp"
npl=$(echo $PL | wc -w)
nxp=$(echo $XPATHS | wc -w)
for k in "${TYPES[@]}"; do inorder ${k%:*} ${k#*:} && [ $ALLINORDER = 0 ] && total=$((total + npl)) || total=$((total + npl + nxp)); done
total=$((total * ROUNDS)); [ $ALLCORE = 1 ] && total=$((total + 2 * ROUNDS))
say ""; say "Plan: $total runs x ${DUR}s + ${COOL}s cooldown = about $(( total * (DUR + COOL + 3) / 60 + 1 )) min"
# The first run after a build was far too slow on several phones (38k instead of 580k H/s on an A55):
# let the phone settle, then do one discarded warm-up run on the first core type.
[ -n "${rev:-}" ] && sleep 30
set -- ${TYPE_CPUS[${TYPES[0]}]}
say "warm-up run (discarded): $(run plain "$(hexmask $1)" 1 | cut -d'|' -f1) H/s"
sleep "$COOL"
n=0
for ((r = 1; r <= ROUNDS; r++)); do
	for k in "${TYPES[@]}"; do
		set -- ${TYPE_CPUS[$k]}; c=$1
		if inorder ${k%:*} ${k#*:} && [ $ALLINORDER = 0 ]; then paths="$PL"; else paths="$PL $XPATHS"; fi
		[ $((r % 2)) = 0 ] && paths=$(echo $paths | tr ' ' '\n' | tac | tr '\n' ' ')
		for p in $paths; do
			n=$((n + 1))
			res=$(run "$p" "$(hexmask $c)" 1); hs=${res%%|*}
			SUM[$k/$p]=$(( ${SUM[$k/$p]:-0} + hs )); CNT[$k/$p]=$(( ${CNT[$k/$p]:-0} + 1 )); PATHSEEN[$k/$p]=${res#*|}
			say "[$n/$total] round $r  $(partname ${k%:*} ${k#*:}) cpu$c  $p: $hs H/s  (${res#*|})"
			[ $n -lt $total ] && sleep "$COOL"
		done
	done
	if [ $ALLCORE = 1 ]; then
		order="default plain"; [ $((r % 2)) = 0 ] && order="plain default"
		for p in $order; do
			n=$((n + 1))
			res=$(run "$p" none "$NCPU"); hs=${res%%|*}
			SUM[all/$p]=$(( ${SUM[all/$p]:-0} + hs )); CNT[all/$p]=$(( ${CNT[all/$p]:-0} + 1 ))
			say "[$n/$total] round $r  all $NCPU cores  $p: $hs H/s"
			[ $n -lt $total ] && sleep "$COOL"
		done
	fi
done

# ---------- report ----------
avg() { [ "${CNT[$1]:-0}" -gt 0 ] && echo $(( SUM[$1] / CNT[$1] )) || echo 0; }
pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%+.1f%%", (a / b - 1) * 100; else printf "n/a" }'; }
say ""; say "================ RESULT (1 thread per core type, mean of $ROUNDS round(s), ${DUR}s runs) ================"
hdr=$(printf '%-18s %-9s %10s %9s' "core type" "id" "plain" "pristine"); for p in $XPATHS; do hdr="$hdr $(printf '%9s' "$p")"; done
printf '%s   %-6s %-8s %s\n' "$hdr" "best" "default" "verdict"
for k in "${TYPES[@]}"; do
	name=$(partname ${k%:*} ${k#*:}); def=$(default_path ${k%:*} ${k#*:})
	pl=$(avg "$k/plain"); best=plain; bh=$pl; cells=""
	for p in plainp $XPATHS; do
		v=$(avg "$k/$p")
		if [ "$v" -gt 0 ]; then cells="$cells $(printf '%9s' "$(pct $v $pl)")"; [ "$p" != plainp ] && [ "$v" -gt "$bh" ] && { best=$p; bh=$v; }
		else cells="$cells $(printf '%9s' -)"; fi
	done
	dv=$(avg "$k/$def"); [ "$dv" -gt 0 ] || dv=$pl
	if [ "$best" = "$def" ]; then verdict="default is best"
	else verdict="best beats default by $(pct $bh $dv)"; fi
	printf '%-18s %-9s %10s%s   %-6s %-8s %s\n' "$name" "$k" "$pl" "$cells" "$best" "$def" "$verdict"
done
say "(plain in H/s; the others as % vs plain on the same core. pristine = plain loop of the x2percore+pristine"
say " binary; it only matters where 'best' is plain, i.e. on in-order cores)"
if [ $ALLCORE = 1 ]; then
	d=$(avg all/default); p=$(avg all/plain)
	say "All $NCPU cores: x2percore default $d H/s, plain everywhere $p H/s ($(pct $d $p))"
fi
say ""
say "TABLE ROWS (paste these back):"
for k in "${TYPES[@]}"; do
	line="ROW $k $(partname ${k%:*} ${k#*:}) maxMHz=${TYPE_MAXF[$k]// MHz/} plain=$(avg "$k/plain")"
	for p in plainp $XPATHS; do v=$(avg "$k/$p"); [ "$v" -gt 0 ] && line="$line $p=$v"; done
	say "$line"
done
say "Log saved to $LOG"
