#!/usr/bin/env bash
# verus-ref-bench.sh v3.7.1 (Termux, or Ubuntu/Debian arm64 such as UserLAnd) - build named Verushash variants of Oink70/CCminer-ARM-optimized,
# prove they match the baseline on THIS CPU, then benchmark them side by side.
#
# Variants (each prints its name in the miner banner):
#   baseline   original code (pinned upstream commit 9ea69fd)
#   zipmix     Haraka512 lane-mixing as the reference zip network instead of lane-insert chains
#   x2 x3 x4   2, 3 or 4 nonces hashed in lockstep, each with its own key copy (out-of-order cores overlap them)
#   x2auto     x2 on out-of-order cores, plain single-nonce loop on in-order cores (A53, A55, ...)
#   x2fuse     two nonces with ONE 64-way jump per round on the pair of cases (measured slower on S8/S20)
#   x2fuseauto x2fuse on out-of-order cores, plain loop on in-order cores
#   x2selauto  x2auto with a branch-free inner choice in case 0x14 (two-nonce path only)
#   x2sel2auto x2selauto plus the same for case 0x18 (one divide per loop step)
#   x2percore  per core at run time: plain on in-order, x2 on Mongoose M1/M2, x2sel2 on M5 and ARM big cores,
#              x2sel on other Mongoose. VERUS_SEL=0|1|3 in the environment forces one choice (testing).
#   pristine   plain loop without the per-round key journal; the key is restored from a pristine copy (aimed at A53/A55)
#   x2percorep x2percore + pristine (the plain loop that in-order cores run under x2percore uses pristine)
#
# In-order cores (plain loop under x2auto/x2percore): Cortex-A34/A35/A53/A55/A510/A520 and Qualcomm Kryo Silver.
# Embedded patch = git diff 9ea69fd..ca801ae of github.com/zzpajk/CCminer-ARM-optimized (branch variants).
#
# Default plan: for every distinct CPU type in /proc/cpuinfo run 1 thread pinned to one core of that
# type and N threads pinned to that cluster, then all cores unpinned. (Pinning uses the miner's own
# --cpu-affinity.) Note upstream's default pins thread i to core i, so plain "-t 4" runs on cores 0-3.
#
# Usage: bash verus-ref-bench.sh [-d SECONDS] [-c COOLDOWN] [-r ROUNDS] [-t "1 4 8"]
#                                [-v "baseline x2auto x2percore x2percorep"] [--skip-build] [--report-only]
#   -d  seconds per benchmark run (30)   -c  cooldown between runs (10)
#   -r  rounds; variants alternate each round to cancel thermal drift (2)
#   -t  thread counts, UNPINNED (default: automatic plan, one pinned run per core type, see below)
#   -v  variants to build/run (default: all)
#   --sweep      instead of the per-core-type plan, run: all big cores + 0, 1, 2 ... all little cores
#                (use with long runs to see heat/power limits, e.g. -d 300 -v "x2auto" --no-ablate --sweep)
#   Compiler-tuning variants: add -t55, -t76 or -tgen to a variant name, e.g. -v "x2auto x2auto-t76 x2auto-tgen":
#                same code, built with -mtune=cortex-a55 / -mtune=cortex-a76 / no -mtune instead of cortex-a53.
#   --no-ablate  skip the "where does the time go" timing section (about 6-8 extra minutes)
#   -j  parallel compile jobs (default: min(cores,4); phones can run out of memory with more)
# No root needed. The report holds device model, SoC, CPU features and hashrates only.

set -u
DUR=20; COOL=8; ROUNDS=1; THREADS=""; VARIANTS="baseline x2auto x2percore x2percorep"; SKIP_BUILD=0; REPORT_ONLY=0; JOBS=""; ABLATE=1; SWEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d) DUR="$2"; shift 2;; -c) COOL="$2"; shift 2;; -r) ROUNDS="$2"; shift 2;;
    -t) THREADS="$2"; shift 2;; -v) VARIANTS="$2"; shift 2;;
    -j) JOBS="$2"; shift 2;;
    --skip-build) SKIP_BUILD=1; shift;; --no-ablate) ABLATE=0; shift;; --sweep) SWEEP=1; shift;; --report-only) REPORT_ONLY=1; shift;;
    *) echo "unknown option: $1"; exit 2;;
  esac
done

PIN=9ea69fdfc74564315a07f9f910ea701a2da9bb50
WORK="${VERUS_WORK:-$HOME/verus-ref}"
REPORT="$WORK/report.txt"; BUILDLOG="$WORK/build.log"; BIN="$WORK/bin"
mkdir -p "$WORK" "$BIN"

have() { command -v "$1" >/dev/null 2>&1; }
prop() { have getprop && getprop "$1" 2>/dev/null; }
vbase() { echo "${1%%-t*}"; }
vtune() { case "$1" in *-t55) echo "-mtune=cortex-a55";; *-t76) echo "-mtune=cortex-a76";; *-tgen) echo "GENERIC";; *) echo "";; esac; }
vflags() { case "$1" in baseline) echo "";; zipmix) echo "-DVERUS_ZIPMIX";; x2) echo "-DVERUS_X2";; x3) echo "-DVERUS_X2 -DVERUS_LANES=3";; x4) echo "-DVERUS_X2 -DVERUS_LANES=4";; x2auto) echo "-DVERUS_X2 -DVERUS_AUTO";; x2fuse) echo "-DVERUS_X2 -DVERUS_FUSE";; x2fuseauto) echo "-DVERUS_X2 -DVERUS_FUSE -DVERUS_AUTO";; x2sel) echo "-DVERUS_X2 -DVERUS_SEL14";; x2selauto) echo "-DVERUS_X2 -DVERUS_SEL14 -DVERUS_AUTO";; x2sel2) echo "-DVERUS_X2 -DVERUS_SEL14 -DVERUS_SEL18";; x2sel2auto) echo "-DVERUS_X2 -DVERUS_SEL14 -DVERUS_SEL18 -DVERUS_AUTO";; x2percore) echo "-DVERUS_X2 -DVERUS_AUTO -DVERUS_PERCORE";; pristine) echo "-DVERUS_PRISTINE";; x2percorep) echo "-DVERUS_X2 -DVERUS_AUTO -DVERUS_PERCORE -DVERUS_PRISTINE";; *) echo "UNKNOWN";; esac; }
# name the variant prints in the banner (and that must be inside its binary)
vmarker() { case "$1" in x2percorep) echo "x2percore+pristine";; *) echo "$1";; esac; }

device_info() {
  echo "== Device =="
  echo "date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "model:       $(prop ro.product.model)$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')"
  echo "os:          $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "proot/chroot: $([ -n "${PROOT_TMP_DIR:-}" ] && echo proot || echo no)"
  echo "board:       $(prop ro.board.platform) / $(prop ro.soc.model) / $(prop ro.hardware)"
  echo "android:     $(prop ro.build.version.release)"
  echo "kernel:      $(uname -sr)  arch: $(uname -m)"
  echo "online cpus: $(nproc 2>/dev/null)"
  echo; echo "== CPU =="
  grep -m1 -i '^Features' /proc/cpuinfo
  echo "CPU part per core (0xd03=A53 0xd05=A55 0xd0a=A75 0xd0b=A76 0xd0d=A77 0xd41=A78 0xd44=X1):"
  awk '/^processor/{p=$3} /^CPU part/{print "  cpu" p ": " $4}' /proc/cpuinfo
  echo "per-core max/current MHz (blank = not readable):"
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    n=${c##*cpu}; mx=$(cat "$c/cpufreq/cpuinfo_max_freq" 2>/dev/null); cu=$(cat "$c/cpufreq/scaling_cur_freq" 2>/dev/null)
    echo "  cpu$n max=${mx:+$((mx/1000))} cur=${cu:+$((cu/1000))} gov=$(cat "$c/cpufreq/scaling_governor" 2>/dev/null)"
  done; echo
}
if [ "$REPORT_ONLY" -eq 1 ]; then device_info; exit 0; fi

# ---------- dependencies ----------
SUDO=""; [ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"
if have pkg && [ -d /data/data/com.termux ]; then
  echo "[1/6] Installing build dependencies (Termux)..."
  pkg install -y git clang lld make autoconf automake libtool pkg-config \
      libcurl libjansson openssl zlib binutils libomp 2>&1 | tail -3
elif have apt-get; then
  echo "[1/6] Installing build dependencies (apt; may ask for your sudo password)..."
  # wait up to 10 minutes if another apt/dpkg holds the lock (e.g. an install someone started by hand)
  $SUDO apt-get -o DPkg::Lock::Timeout=600 update -qq 2>&1 | tail -2
  $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y git clang lld make autoconf automake libtool pkg-config binutils \
      libcurl4-openssl-dev libjansson-dev libssl-dev zlib1g-dev 2>&1 | tail -3
else
  echo "[1/6] Neither pkg nor apt-get found: install git, clang, lld, autotools and libcurl/jansson/openssl/zlib dev packages yourself."
fi
# Fail early and clearly if something is still missing.
MISSING=""
for c in git clang clang++ ld.lld make autoconf automake pkg-config; do have "$c" || MISSING="$MISSING $c"; done
for h in curl/curl.h jansson.h openssl/ssl.h zlib.h; do
  printf '#include <%s>\n' "$h" | clang -E -x c - >/dev/null 2>&1 || MISSING="$MISSING header:$h"
done
if [ -n "$MISSING" ] && [ "$SKIP_BUILD" -eq 0 ] && [ "$REPORT_ONLY" -eq 0 ]; then
  echo "Missing:$MISSING"
  echo "Install them (Ubuntu/Debian: sudo apt-get install clang lld autoconf automake libtool pkg-config libcurl4-openssl-dev libjansson-dev libssl-dev zlib1g-dev git make) and run again."
  exit 1
fi
[ -z "$JOBS" ] && { JOBS=$(nproc 2>/dev/null || echo 2); [ "$JOBS" -gt 4 ] && JOBS=4; }

# ---------- source: pinned upstream + embedded variants patch ----------
if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "[2/6] Fetching pinned source $PIN (log: $BUILDLOG)..."
  rm -rf "$WORK/src-orig" "$WORK"/build-*; : > "$BUILDLOG"
  mkdir "$WORK/src-orig" && ( cd "$WORK/src-orig" && git init -q . && \
    git remote add origin https://github.com/Oink70/CCminer-ARM-optimized.git && \
    { git fetch -q --depth 1 origin "$PIN" || git fetch -q origin; } && git checkout -q "$PIN" ) >>"$BUILDLOG" 2>&1 \
    || { echo "fetch failed"; tail -20 "$BUILDLOG"; exit 1; }
  # Patch is embedded below (gzip+base64). It only ADDS verus/verus_variant.h, tests/verus_difftest.c,
  # a macro block in verus/haraka.h that is inert unless -DVERUS_ZIPMIX, one banner line, a benchmark-mode
  # fix in verus/verusscan.cpp (upstream's --benchmark never finished a scan call for Verus), and it blanks the
  # sample wallet/pool in ccminer.conf (upstream ships a default wallet there that is auto-loaded).
  sed -n '/^__PATCH__$/,$p' "$0" | tail -n +2 | base64 -d | gunzip > "$WORK/variants.patch" \
    && ( cd "$WORK/src-orig" && git apply --whitespace=nowarn "$WORK/variants.patch" ) >>"$BUILDLOG" 2>&1 \
    || { echo "patch failed"; tail -20 "$BUILDLOG"; exit 1; }

  echo 'int main(void){return 0;}' > "$WORK/probe.c"
  # Upstream's configure.sh was written for a recent clang. Older clangs (Ubuntu 20.04 ships clang 10) reject some
  # of its flags ("unknown argument") and then configure fails with "C compiler cannot create executables".
  # Probe each flag with the installed compiler/linker and drop the ones it rejects. Every variant gets the same
  # flags on a given device, so comparisons stay fair; the removed flags are listed in the report.
  RMF=""
  probe() { clang -x c "$WORK/probe.c" "$@" -o "$WORK/probe.out" >/dev/null 2>&1; }
  probe -ffinite-loops || RMF="$RMF|-ffinite-loops"
  probe -mfix-cortex-a53-835769 || RMF="$RMF|-mfix-cortex-a53-835769"
  probe -mllvm -enable-loop-distribute || RMF="$RMF|-mllvm -enable-loop-distribute"
  if ! probe -O3 -flto -fuse-ld=lld; then RMF="$RMF|-flto|-fuse-ld=lld|-Wl,-hugetlbfs-align"
  elif ! probe -fuse-ld=lld -Wl,-hugetlbfs-align; then RMF="$RMF|-Wl,-hugetlbfs-align"; fi
  RMF=${RMF#|}
  [ -n "$RMF" ] && echo "  note: this clang/linker rejects: $(echo "$RMF" | tr '|' ' ') -> building without them"
  echo "[3/6] Building variants: $VARIANTS ($JOBS compile jobs)"
  for v in $VARIANTS; do
    vb=$(vbase "$v"); tn=$(vtune "$v")
    fl=$(vflags "$vb"); [ "$fl" = "UNKNOWN" ] && { echo "unknown variant $v"; exit 1; }
    d="$WORK/build-$v"; rm -rf "$d"; cp -r "$WORK/src-orig" "$d"
    echo "  - $v ${fl:+($fl)} ${tn:+[tune: $tn]}"
    # The upstream tree ships generated build files (configure, Makefile.in) AND stale build products
    # (a prebuilt ccminer and *.o files). Regenerating with autogen fails on current autoconf, and is
    # not needed, so use the shipped configure as-is but delete every old build product first so nothing
    # stale is linked. configure.sh is upstream's own flag set (clang, lld, -mtune=cortex-a53).
    ( cd "$d" && find . -name '*.o' -delete && rm -f ccminer *.opt.yaml config.status && \
        { if [ -n "$RMF" ]; then echo "$RMF" | tr '|' '\n' | while IFS= read -r f; do sed -i "s# $f##g" configure.sh; done; fi; true; } && \
        { if [ "$tn" = GENERIC ]; then sed -i 's# -mtune=cortex-a53##g' configure.sh; elif [ -n "$tn" ]; then sed -i "s#-mtune=cortex-a53#$tn#g" configure.sh; fi; true; } && \
        ./configure.sh && make -j"$JOBS" CPPFLAGS="$fl" ) >>"$BUILDLOG" 2>&1
    if [ -x "$d/ccminer" ] && [ "$d/ccminer" -nt "$d/verus/verus_variant.h" ]; then
      # Prove the right code was linked: the variant name literal must be in the binary.
      case "$vb" in
        baseline) grep -q 'baseline+' "$d/ccminer" && { echo "  !! $v binary contains variant code"; exit 1; } ;;
        *)        grep -q "baseline+$(vmarker "$vb")" "$d/ccminer" || { echo "  !! $v binary lacks the variant marker (stale objects?)"; exit 1; } ;;
      esac
      cp "$d/ccminer" "$BIN/ccminer-$v"
    else echo "BUILD FAILED for $v. First errors, then last 25 lines of $BUILDLOG:"; grep -m8 -E 'error|Error|cannot find|No such file' "$BUILDLOG"; echo ...; tail -25 "$BUILDLOG"
      [ -f "$d/config.log" ] && { echo "--- config.log (compiler test) ---"; grep -E '^(clang|ld\.lld|ld|/usr/bin/ld)[^ ]*: (error|warning)|unknown argument|cannot find|conftest' "$d/config.log" | grep -v '^ac_cv\|^[0-9]*:ac_' | tail -12; }
      echo "Send me the text above (and $BUILDLOG if you can)."; exit 1; fi
  done
fi

# ---------- bit-exactness: every variant vs baseline on this CPU ----------
echo "[4/6] Differential test on this CPU (variant must equal baseline)"
DT_RESULTS=""
SRC="$WORK/src-orig"
for v in $VARIANTS; do
  vb=$(vbase "$v"); [ "$vb" = "baseline" ] && continue
  fl=$(vflags "$vb"); T="$WORK/dt-$v"; rm -rf "$T"; mkdir -p "$T"
  case "$fl" in *VERUS_PRISTINE*)
    # pristine restore vs the original journal + FixKey, key kept across 1000 nonces at a time
    CFL="-O2 -march=armv8-a+crypto -fno-strict-aliasing -I$SRC -I$SRC/verus"
    if ( cd "$SRC" && clang++ $CFL -std=gnu++11 -c verus/verus_clhash_portable.cpp -o "$T/clp.o" && \
         clang $CFL -c verus/haraka.c -o "$T/hk.o" && clang $CFL -c verus/haraka_portable.c -o "$T/hkp.o" && \
         clang++ $CFL -std=gnu++11 tests/verus_pristinetest.cpp "$T/clp.o" "$T/hk.o" "$T/hkp.o" -o "$T/pristinetest" ) >>"$BUILDLOG" 2>&1; then
      R=$("$T/pristinetest" 200000 | tail -1); DT_RESULTS="${DT_RESULTS}  $v: $R
"
    else DT_RESULTS="${DT_RESULTS}  $v: pristinetest did not build (see $BUILDLOG)
"; fi
    [ "$vb" = pristine ] && continue;;
  esac
  case "$vb" in x2*|x3|x4)
    CFL="-O2 -march=armv8-a+crypto -fno-strict-aliasing -I$SRC -I$SRC/verus"
    if ( cd "$SRC" && clang++ $CFL -std=gnu++11 $fl -c verus/verus_clhash_portable.cpp -o "$T/cl.o" && \
         clang $CFL -c verus/haraka.c -o "$T/hk.o" && clang $CFL -c verus/haraka_portable.c -o "$T/hkp.o" && \
         clang++ $CFL -std=gnu++11 $fl tests/verus_x2test.cpp "$T/cl.o" "$T/hk.o" "$T/hkp.o" -o "$T/x2test" ) >>"$BUILDLOG" 2>&1; then
      R=$("$T/x2test" 200000 | tail -1); DT_RESULTS="${DT_RESULTS}  $v: $R
"
    else DT_RESULTS="${DT_RESULTS}  $v: x2test did not build (see $BUILDLOG)
"; fi
    continue;;
  esac
  CFL="-O2 -march=armv8-a+crypto -fno-strict-aliasing -I$SRC -I$SRC/verus"
  if ( cd "$SRC" && clang $CFL -Dharaka512_keyed=haraka512_keyed_base -c verus/haraka.c -o "$T/hb.o" && \
       clang $CFL $fl -Dharaka512_keyed=haraka512_keyed_var -c verus/haraka.c -o "$T/hv.o" && \
       clang $CFL tests/verus_difftest.c "$T/hb.o" "$T/hv.o" -o "$T/difftest" ) >>"$BUILDLOG" 2>&1; then
    R=$("$T/difftest" 2000000 | tail -1); DT_RESULTS="${DT_RESULTS}  $v: $R
"
  else DT_RESULTS="${DT_RESULTS}  $v: difftest did not build (see $BUILDLOG)
"; fi
done
printf '%s' "$DT_RESULTS"
case "$DT_RESULTS" in *FAIL*|*"did not build"*) echo "A variant is not verified; benchmarking continues but DO NOT trust it for mining.";; esac

# ---------- instruction check ----------
OBJDUMP=""; for o in objdump llvm-objdump; do have "$o" && { OBJDUMP="$o"; break; }; done
INSN=""
for v in $VARIANTS; do
  if [ -n "$OBJDUMP" ]; then
    a=$("$OBJDUMP" -d "$BIN/ccminer-$v" 2>/dev/null | grep -c -E '\baese\b'); p=$("$OBJDUMP" -d "$BIN/ccminer-$v" 2>/dev/null | grep -c -E '\bpmull2?\b')
  else a="n/a"; p="n/a"; fi
  INSN="${INSN}  $v: aese=$a pmull=$p (0 would mean no hardware crypto)
"
done

# ---------- benchmark (variants alternate within each round) ----------
NCPU=$(nproc 2>/dev/null || echo 1)
# cpu number + "implementer:part" for every core
CORES=$(awk '/^processor/{p=$3} /^CPU implementer/{i=$4} /^CPU part/{print p, i ":" $4}' /proc/cpuinfo)
PLAN=""   # lines: label|threads|affinity-mask-or-empty
if [ -n "$THREADS" ]; then
  for t in $THREADS; do PLAN="${PLAN}${t}T-unpinned|${t}|
"; done
elif [ "$SWEEP" -eq 1 ]; then
  # in-order little cores: ARM A34/A35/A53/A55/A510/A520 and Qualcomm Kryo Silver (0x51:801/803/805)
  ISLIT='{split($2,a,":"); lit=(a[1]=="0x41" && (a[2]=="0xd02"||a[2]=="0xd03"||a[2]=="0xd04"||a[2]=="0xd05"||a[2]=="0xd46"||a[2]=="0xd80")) || (a[1]=="0x51" && (a[2]=="0x801"||a[2]=="0x803"||a[2]=="0x805"))}'
  BIGS=$(echo "$CORES" | awk "$ISLIT"' !lit{print $1}'); LITS=$(echo "$CORES" | awk "$ISLIT"' lit{print $1}')
  nb=$(echo "$BIGS" | grep -c .); nl=$(echo "$LITS" | grep -c .); bmask=0
  for c in $BIGS; do bmask=$((bmask | (1<<c))); done
  k=0; m=$bmask
  while [ "$k" -le "$nl" ]; do
    [ $((nb+k)) -gt 0 ] && PLAN="${PLAN}${nb}big+${k}little|$((nb+k))|$(printf '0x%x' $m)
"
    k=$((k+1)); c=$(echo "$LITS" | sed -n "${k}p"); [ -n "$c" ] && m=$((m | (1<<c)))
  done
else
  for k in $(echo "$CORES" | awk '{print $2}' | sort -u); do
    list=$(echo "$CORES" | awk -v k="$k" '$2==k{print $1}')
    first=$(echo "$list" | head -1); cnt=$(echo "$list" | wc -l); mask=0
    for c in $list; do mask=$((mask | (1<<c))); done
    PLAN="${PLAN}1T@cpu${first}[${k}]|1|$(printf '0x%x' $((1<<first)))
"
    [ "$cnt" -gt 1 ] && PLAN="${PLAN}${cnt}T@cores[${k}]|${cnt}|$(printf '0x%x' $mask)
"
  done
  PLAN="${PLAN}${NCPU}T@all|${NCPU}|
"
fi
PLAN=$(printf '%s' "$PLAN" | sed '/^$/d')
echo "[5/6] Benchmark plan (label|threads|mask):"; echo "$PLAN" | sed 's/^/  /'
NVAR=$(set -- $VARIANTS; echo $#); NCFG=$(echo "$PLAN" | wc -l); TOTAL=$((NCFG*ROUNDS*NVAR))
echo "      variants [$VARIANTS], $ROUNDS round(s), ${DUR}s runs, ${COOL}s cooldown"
echo "      $TOTAL runs, about $(( (TOTAL*(DUR+COOL)+59)/60 )) minutes. Nothing is frozen: one line is printed per finished run."
RAW="$WORK/raw.tsv"; : > "$RAW"; idx=0; RUN=0
rm -f "$WORK"/bench_*.log "$WORK"/samp_*.txt
# big vs little cores (little = in-order: ARM A34/A35/A53/A55/A510/A520, Kryo Silver), used for the clock-speed columns
ISLIT='{split($2,a,":"); lit=(a[1]=="0x41" && (a[2]=="0xd02"||a[2]=="0xd03"||a[2]=="0xd04"||a[2]=="0xd05"||a[2]=="0xd46"||a[2]=="0xd80")) || (a[1]=="0x51" && (a[2]=="0x801"||a[2]=="0x803"||a[2]=="0x805"))}'
BIGS=$(echo "$CORES" | awk "$ISLIT"' !lit{print $1}' | tr '\n' ' '); LITS=$(echo "$CORES" | awk "$ISLIT"' lit{print $1}' | tr '\n' ' ')
# every 5 s while a run is going: average current MHz of big cores, of little cores, and the hottest thermal zone (C)
sampler() {
  while :; do
    b=0; nb=0; for c in $BIGS; do f=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null) && { b=$((b+f)); nb=$((nb+1)); }; done
    l=0; nl=0; for c in $LITS; do f=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null) && { l=$((l+f)); nl=$((nl+1)); }; done
    tm=0; for z in /sys/class/thermal/thermal_zone*/temp; do v=$(cat "$z" 2>/dev/null) || continue; case "$v" in ''|*[!0-9]*) continue;; esac
      [ "$v" -lt 1000 ] && v=$((v*1000)); [ "$v" -lt 150000 ] && [ "$v" -gt "$tm" ] && tm=$v; done
    # battery temperature (tenths of a degree C); readable on phones where the thermal zones are not
    bt=$(cat /sys/class/power_supply/battery/temp 2>/dev/null); case "$bt" in ''|*[!0-9]*) bt=0;; esac
    echo "$([ $nb -gt 0 ] && echo $((b/nb/1000)) || echo 0) $([ $nl -gt 0 ] && echo $((l/nl/1000)) || echo 0) $((tm/1000)) $((bt/10))"
    sleep 5
  done
}
echo "$PLAN" | while IFS='|' read -r label t mask; do
  idx=$((idx+1))
  r=1; while [ "$r" -le "$ROUNDS" ]; do
    # reverse the variant order every other round so no variant always runs on a phone the others heated up
    VORD="$VARIANTS"; [ $((r % 2)) -eq 0 ] && VORD=$(echo $VARIANTS | tr ' ' '\n' | tac | tr '\n' ' ')
    for v in $VORD; do
      LOG="$WORK/bench_${v}_${idx}_r${r}.log"; SAMP="$WORK/samp_${v}_${idx}_r${r}.txt"
      RUN=$((RUN+1)); printf '  [%d/%d] %-22s %-11s round %d ... ' "$RUN" "$TOTAL" "$label" "$v" "$r"
      sampler > "$SAMP" 2>/dev/null & SP=$!
      "$BIN/ccminer-$v" -a verus --benchmark -t "$t" ${mask:+--cpu-affinity "$mask"} --time-limit "$DUR" --no-color >"$LOG" 2>&1 </dev/null
      kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
      HSEND=$(grep -E '^[0-9]+$' "$LOG" | tail -1)
      # time-averaged rate from the periodic "Total:" lines (first 20% dropped as warm-up); the final number alone
      # is only the rate at the very end of the run
      HSAVG=$(grep -o 'Total: [0-9.]* [kMG]*H/s' "$LOG" | awk '{u=$3; m=1; if(u~/^k/)m=1e3; else if(u~/^M/)m=1e6; else if(u~/^G/)m=1e9; v[n++]=$2*m}
        END{ if(n<5){exit} s=0; c=0; for(i=int(n*0.2);i<n;i++){s+=v[i];c++} printf "%.0f", s/c }')
      HS=${HSAVG:-$HSEND}
      MS=$(awk 'NR>1{b+=$1;l+=$2;n++; if($3>t)t=$3; if($4>bt)bt=$4} END{if(n) printf "%d\t%d\t%d\t%d", b/n, l/n, t, bt; else printf "0\t0\t0\t0"}' "$SAMP")
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$label" "$v" "$r" "${HS:-0}" "$MS" >> "$RAW"
      echo "${HS:-no result} H/s  (MHz big/little, max C, battery C: $(echo "$MS" | tr '\t' ' '))"
      [ -z "$HS" ] && { echo "  (no result: $v $label r=$r; last lines of $LOG)"; tail -6 "$LOG"; }
      [ "$RUN" -lt "$TOTAL" ] && sleep "$COOL"   # no cooldown after the last run
    done
    r=$((r+1))
  done
done

# ---------- ablation: where does the time go on each core type? ----------
# Each build removes ONE thing on purpose (the hash is wrong, this is timing only) to show the most that
# optimising it could ever win. Single thread, pinned with taskset to the first core of each core type.
ABL_REPORT=""
if [ "$ABLATE" -eq 1 ] && [ -f "$WORK/src-orig/tests/verus_ablate.cpp" ]; then
  echo "[5b] Ablation timings (where does the time go?), about 7-9 minutes..."
  AD="$WORK/abl"; rm -rf "$AD"; mkdir -p "$AD"; SRC="$WORK/src-orig"
  CF="-O2 -march=armv8-a+crypto -fno-strict-aliasing -I$SRC -I$SRC/verus"
  ABLN="full pristine nodiv innerfix switchfix nofix noharaka nomulhrs x2full x2nodiv x2innerfix x2switchfix x2nofix x2noharaka x2nomulhrs"
  # x2* = the same experiments on the two-nonce path (what still limits x2 on this core type)
  ablf() { x=""; n="$1"; case "$n" in x2*) x="-DVERUS_X2"; n="${n#x2}";; esac
    case "$n" in full) echo "$x";; pristine) echo "$x -DVERUS_PRISTINE";; nodiv) echo "$x -DVERUS_ABL_NODIV";; innerfix) echo "$x -DVERUS_ABL_INNER_FIXED";;
    switchfix) echo "$x -DVERUS_ABL_SWITCH_FIXED";; nofix) echo "$x -DVERUS_ABL_NOFIX";; noharaka) echo "$x -DVERUS_ABL_NOHARAKA";;
    nomulhrs) echo "$x -DVERUS_ABL_NOMULHRS";; esac; }
  ABL_OK=1
  ( cd "$SRC" && clang $CF -c verus/haraka.c -o "$AD/hk.o" && clang $CF -c verus/haraka_portable.c -o "$AD/hkp.o" ) >>"$BUILDLOG" 2>&1 || ABL_OK=0
  for n in $ABLN; do
    [ "$ABL_OK" -eq 1 ] || break
    f=$(ablf "$n")
    ( cd "$SRC" && clang++ $CF -std=gnu++11 $f -c verus/verus_clhash_portable.cpp -o "$AD/cl-$n.o" && \
      clang++ $CF -std=gnu++11 $f tests/verus_ablate.cpp "$AD/cl-$n.o" "$AD/hk.o" "$AD/hkp.o" -o "$AD/abl-$n" ) >>"$BUILDLOG" 2>&1 || ABL_OK=0
  done
  if [ "$ABL_OK" -eq 1 ]; then
    PIN_CMD=""; have taskset && PIN_CMD="taskset -c"
    ABLRAW="$WORK/abl.tsv"; : > "$ABLRAW"
    for k in $(echo "$CORES" | awk '{print $2}' | sort -u); do
      first=$(echo "$CORES" | awk -v k="$k" '$2==k{print $1}' | head -1)
      for r in 1 2; do for n in $ABLN; do
        if [ -n "$PIN_CMD" ]; then hs=$($PIN_CMD "$first" "$AD/abl-$n" 3 2>/dev/null | head -1)
        else hs=$("$AD/abl-$n" 3 2>/dev/null | head -1); fi
        printf '%s\t%s\t%s\t%s\n' "$k" "cpu$first" "$n" "${hs:-0}" >> "$ABLRAW"
      done; done
      echo "  core type $k (cpu$first) done"
    done
    ABL_REPORT=$(awk -F'\t' '{ key=$1 SUBSEP $3; lab[$1]=$2; n[key]++; s[key]+=$4; T[$1]=1; N[$3]=1 }
      END { for (t in T) { fk=t SUBSEP "full"; b=(fk in n)? s[fk]/n[fk] : 0
        printf "  core type %s (%s)%s\n", t, lab[t], "'"$([ -n "$PIN_CMD" ] || echo ' [UNPINNED: taskset missing]')"'"
        split("full pristine nodiv innerfix switchfix nofix noharaka nomulhrs x2full x2nodiv x2innerfix x2switchfix x2nofix x2noharaka x2nomulhrs", O, " ")
        x2k=t SUBSEP "x2full"; b2=(x2k in n)? s[x2k]/n[x2k] : 0
        for (i=1;i<=15;i++) { v=O[i]; k=t SUBSEP v; if (!(k in n)) continue; m=s[k]/n[k]; bb=(v ~ /^x2/)? b2 : b
          if (v=="x2full") printf "    %-12s %10.0f H/s  %s   <- two-nonce path, percentages below are vs this line\n", v, m, (b>0 ? sprintf("%+.1f%% vs full", (m/b-1)*100) : "")
          else printf "    %-12s %10.0f H/s  %s\n", v, m, (bb>0 ? sprintf("%+.1f%%", (m/bb-1)*100) : "") } } }' "$ABLRAW")
  else ABL_REPORT="  (ablation harness did not build, see $BUILDLOG)"; fi
fi

# ---------- report ----------
echo "[6/6] Writing report to $REPORT"
{
  device_info
  echo "== Build =="
  echo "upstream commit: $PIN (pinned)"
  echo "compiler:        $(clang --version 2>/dev/null | head -1)"
  [ -n "${RMF:-}" ] && echo "flags dropped:   $(echo "$RMF" | tr '|' ' ')  (rejected by this clang/linker)"
  echo "variants:        $VARIANTS"
  printf '%s' "$INSN"
  echo; echo "== Differential test (variant output == baseline output, 2,000,000 random inputs) =="
  printf '%s' "${DT_RESULTS:-  (baseline only)
}"
  echo; echo "== Verushash benchmark (${DUR}s runs, ${ROUNDS} round(s), ${COOL}s cooldown) =="
  echo "  (H/s = time-averaged over each run; MHz = average clock of big / little cores during the run;"
  echo "   max_C = hottest thermal sensor, 0 = not readable here; batt_C = hottest battery reading)"
  echo "config                   variant        mean_H/s   min_H/s   max_H/s   vs_baseline  MHz_big MHz_lit  max_C batt_C"
  awk -F'\t' '
    { k=$1 SUBSEP $3; lab[$1]=$2; n[k]++; s[k]+=$5; if(!(k in mn)||$5<mn[k])mn[k]=$5; if($5>mx[k])mx[k]=$5; C[$1]=1; V[$3]=1
      fb[k]+=$6; fl[k]+=$7; if($8>tc[k])tc[k]=$8; if($9>tb[k])tb[k]=$9 }
    END { for (c in C) { bk=c SUBSEP "baseline"; b=((bk in n) ? s[bk]/n[bk] : 0)
        for (v in V) { k=c SUBSEP v; if (!(k in n)) continue; m=s[k]/n[k]
          printf "%03d %-24s %-12s %10.0f %9.0f %9.0f   %-11s %7.0f %7.0f %6d %6d\n", c, lab[c], v, m, mn[k], mx[k], (b>0 ? sprintf("%+.2f%%", (m/b-1)*100) : "n/a"), fb[k]/n[k], fl[k]/n[k], tc[k], tb[k] } } }' "$RAW" | sort -k1,1n -k3,3 | cut -c5-
  echo; echo "(a difference smaller than the min-max spread within a variant is noise)"
  if ls "$WORK"/bench_*auto_*.log "$WORK"/bench_*percore*_*.log >/dev/null 2>&1; then
    echo; echo "== auto/percore variants: which path did each thread take? (nonces hashed per step, per cpu) =="
    cat "$WORK"/bench_*auto_*.log "$WORK"/bench_*percore*_*.log 2>/dev/null | grep -h "Verus thread" | sed 's/^\[[^]]*\] *//; s/thread [0-9]* on/thread on/' | sort | uniq -c | sed 's/^/  /'
  fi
  if [ -n "$ABL_REPORT" ]; then
    echo; echo "== Where does the time go? (single thread; each line removes ONE thing on purpose, hash is wrong, timing only) =="
    echo "  full=real pipeline  nodiv=no 64-bit divide  innerfix=predictable inner branches  switchfix=predictable case order"
    echo "  nofix=no key restore  noharaka=no final Haraka  nomulhrs=no mulhrs.   Percent = the most that optimising it could win."
    echo "  pristine is NOT an ablation: it is the real pristine variant (correct hashes) timed in the same harness."
    printf '%s\n' "$ABL_REPORT"
  fi
  echo; echo "== Post-run CPU frequencies (a big drop vs max above = throttling) =="
  for c in /sys/devices/system/cpu/cpu[0-9]*; do n=${c##*cpu}; cu=$(cat "$c/cpufreq/scaling_cur_freq" 2>/dev/null); echo "  cpu$n cur=${cu:+$((cu/1000))}"; done
} | tee "$REPORT"
echo; echo "Done. Paste the report above (or send $REPORT) back to Claude."
exit 0
__PATCH__
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
LbipW3RHBxSesadLbuhgbT76/0EEC6yl/gIA
