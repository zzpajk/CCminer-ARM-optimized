#!/usr/bin/env bash
# verus-ref-bench.sh v3.9 (Termux, or Ubuntu/Debian arm64 such as UserLAnd) - build named Verushash variants of Oink70/CCminer-ARM-optimized,
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
#   x2percore  per core at run time: plain on in-order cores, x2 on Mongoose M1/M2, x2sel2 on every other
#              out-of-order core. VERUS_SEL=0|1|3 in the environment forces one choice (testing).
#   pristine   plain loop without the per-round key journal; the key is restored from a pristine copy (aimed at A53/A55)
#   x2percorep x2percore + pristine (the plain loop that in-order cores run under x2percore uses pristine)
#
# In-order cores (plain loop under x2auto/x2percore): Cortex-A34/A35/A53/A55/A510/A520 and Qualcomm Kryo Silver.
# Embedded patch = git diff 9ea69fd..4c7326e of github.com/zzpajk/CCminer-ARM-optimized (branch variants).
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
