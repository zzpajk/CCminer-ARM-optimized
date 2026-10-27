#!/usr/bin/env bash
# verus-ref-bench.sh v3.8 (Termux, or Ubuntu/Debian arm64 such as UserLAnd) - build named Verushash variants of Oink70/CCminer-ARM-optimized,
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
#   x2percore  per core at run time: plain on in-order, x2 on Mongoose M1/M2, x2sel on M3, x2sel2 on M4/M5 and
#              ARM big cores. VERUS_SEL=0|1|3 in the environment forces one choice (testing).
#   pristine   plain loop without the per-round key journal; the key is restored from a pristine copy (aimed at A53/A55)
#   x2percorep x2percore + pristine (the plain loop that in-order cores run under x2percore uses pristine)
#
# In-order cores (plain loop under x2auto/x2percore): Cortex-A34/A35/A53/A55/A510/A520 and Qualcomm Kryo Silver.
# Embedded patch = git diff 9ea69fd..cdd3bf2 of github.com/zzpajk/CCminer-ARM-optimized (branch variants).
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
55OO2/+yPXH8qT2ZGs0n4ol48v8Bk3vfyX//AgA=
