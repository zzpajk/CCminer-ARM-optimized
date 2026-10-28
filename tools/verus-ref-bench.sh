#!/usr/bin/env bash
# verus-ref-bench.sh v4.5 (Termux, or Ubuntu/Debian arm64 such as UserLAnd) - build named Verushash variants of Oink70/CCminer-ARM-optimized,
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
#   <variant>-pgo  the same code built with clang profile-guided optimisation: an instrumented build is
#              trained on THIS phone for ~50 s (plain loop and the two-nonce paths), then rebuilt with the
#              profile. Needs llvm-profdata (package llvm), installed with the other dependencies.
#   <variant>-cNN  the same code built with clang NN (e.g. x2percorep-c15) from /usr/lib/llvm-NN, installed
#              from the distribution if missing (clang-NN lld-NN llvm-NN), else from LLVM's apt repository
#              (apt.llvm.org, added once). Combines: x2percorep-c17-pgo.
#   <variant>-gcc  the same code built with GCC 12 or newer (same flags translated; LTO via gcc-ar). Older GCC
#              cannot build it (no __builtin_shufflevector); the variant is skipped if no GCC >= 12 is available.
#   A compiler variant (-cNN, -gcc) that fails to build is dropped with a note; the run continues.
#
# In-order cores (plain loop under x2auto/x2percore): Cortex-A34/A35/A53/A55/A510/A520 and Qualcomm Kryo Silver.
# Embedded patch = git diff 9ea69fd..d8d896c of github.com/zzpajk/CCminer-ARM-optimized (branch variants).
#
# Default plan: for every distinct CPU type in /proc/cpuinfo run 1 thread pinned to one core of that
# type and N threads pinned to that cluster, then all cores unpinned. (Pinning uses the miner's own
# --cpu-affinity.) Note upstream's default pins thread i to core i, so plain "-t 4" runs on cores 0-3.
#
# Usage: bash verus-ref-bench.sh [-d SECONDS] [-c COOLDOWN] [-r ROUNDS] [-t "1 4 8"]
#                                [-v "baseline x2percorep x2percorep-pgo"] [--skip-build] [--report-only]
#   -d  seconds per benchmark run (30)   -c  cooldown between runs (10)
#   -r  rounds; variants alternate each round to cancel thermal drift (2)
#   -t  thread counts, UNPINNED (default: automatic plan, one pinned run per core type, see below)
#   -v  variants to build/run (default: all)
#   --sweep      instead of the per-core-type plan, run: all big cores + 0, 1, 2 ... all little cores
#                (use with long runs to see heat/power limits, e.g. -d 300 -v "x2auto" --no-ablate --sweep)
#   Compiler-tuning variants: add -t55, -t76 or -tgen to a variant name, e.g. -v "x2auto x2auto-t76 x2auto-tgen":
#                same code, built with -mtune=cortex-a55 / -mtune=cortex-a76 / no -mtune instead of cortex-a53.
#   Code generation variants (clang only), after the name and before -cNN: -al4/-al5/-al6 align jump targets
#                to 16/32/64 bytes; -jtN sets the minimum case count for a jump table (e.g. x2percorep-jt4-c18).
#   --no-ablate  skip the "where does the time go" timing section (about 6-8 extra minutes)
#   -j  parallel compile jobs (default: min(cores,4); phones can run out of memory with more)
# No root needed. The report holds device model, SoC, CPU features and hashrates only.

set -u
DUR=20; COOL=8; ROUNDS=1; THREADS=""; VARIANTS="baseline x2percorep x2percorep-pgo"; SKIP_BUILD=0; REPORT_ONLY=0; JOBS=""; ABLATE=1; SWEEP=0
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
vbase() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-jt[0-9]*}"; b="${b%-al[0-9]}"; echo "${b%%-t*}"; }
vgcc() { case "${1%-pgo}" in *-gcc) return 0;; esac; return 1; }
vcc() { local b="${1%-pgo}"; case "$b" in *-c[0-9]*) echo "${b##*-c}";; *) echo "";; esac; }
vpgo() { case "$1" in *-pgo) return 0;; esac; return 1; }
# Code generation options, as "-mllvm" option values (the build passes them to the compiler AND, as
# -Wl,-mllvm,..., to the linker: with -flto the machine code is generated at link time and clang does not
# forward -mllvm there by itself).
# -alN: align every basic block that is only reached by a jump (the case targets of the hashing switch,
#       loop heads) to 2^N bytes, so the refetch after a mispredicted jump starts at a fetch-block boundary.
# -jtN: minimum number of switch cases for a jump table. LLVM 18 raised it on AArch64 from 4 to 13, so the
#       8-way case switch of the hash became a tree of ~3 unpredictable conditional branches per round
#       instead of one indirect jump. -jt4 with clang >= 18 restores the old lowering; -jt13 with clang <= 17
#       reproduces the new one. (The option is named differently before and after LLVM 18.)
valign() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-jt[0-9]*}"; case "$b" in *-al[0-9]) echo "-align-all-nofallthru-blocks=${b##*-al}";; *) echo "";; esac; }
vjt() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; case "$b" in *-jt[0-9]*) echo "${b##*-jt}";; *) echo "";; esac; }
vtune() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-jt[0-9]*}"; case "${b%-al[0-9]}" in *-t55) echo "-mtune=cortex-a55";; *-t76) echo "-mtune=cortex-a76";; *-tgen) echo "GENERIC";; *) echo "";; esac; }
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
  $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y git clang lld llvm make autoconf automake libtool pkg-config binutils \
      libcurl4-openssl-dev libjansson-dev libssl-dev zlib1g-dev 2>&1 | tail -3
else
  echo "[1/6] Neither pkg nor apt-get found: install git, clang, lld, autotools and libcurl/jansson/openssl/zlib dev packages yourself."
fi
# compilers asked for with -cNN
for v in $VARIANTS; do
  nn=$(vcc "$v"); [ -z "$nn" ] && continue
  if [ ! -x "/usr/lib/llvm-$nn/bin/clang" ] || [ ! -x "/usr/lib/llvm-$nn/bin/ld.lld" ]; then
    echo "      installing clang-$nn lld-$nn llvm-$nn for variant $v ..."
    if have apt-get; then $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y "clang-$nn" "lld-$nn" "llvm-$nn" 2>&1 | tail -2; fi
    if [ ! -x "/usr/lib/llvm-$nn/bin/clang" ] && have apt-get; then
      # not in the distribution: use LLVM's own repository for this Ubuntu release
      cn=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
      if [ -n "$cn" ]; then
        echo "      adding apt.llvm.org (llvm-toolchain-$cn-$nn) ..."
        key="/etc/apt/trusted.gpg.d/apt.llvm.org.asc"
        if [ ! -s "$key" ]; then
          if have curl; then curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | $SUDO tee "$key" >/dev/null
          elif have wget; then wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | $SUDO tee "$key" >/dev/null; fi
        fi
        echo "deb http://apt.llvm.org/$cn/ llvm-toolchain-$cn-$nn main" | $SUDO tee "/etc/apt/sources.list.d/llvm-$nn.list" >/dev/null
        $SUDO apt-get -o DPkg::Lock::Timeout=600 update -qq 2>&1 | tail -2
        $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y "clang-$nn" "lld-$nn" "llvm-$nn" 2>&1 | tail -2
      fi
    fi
  fi
  [ -x "/usr/lib/llvm-$nn/bin/clang" ] || echo "      !! clang-$nn not available here; variant $v will be skipped"
done
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
  rmf_for() { # compiler -> the configure.sh flags it rejects, '|'-separated
    local r=""
    probe() { "$1" -x c "$WORK/probe.c" "${@:2}" -o "$WORK/probe.out" >/dev/null 2>&1; }
    probe "$1" -ffinite-loops || r="$r|-ffinite-loops"
    probe "$1" -mfix-cortex-a53-835769 || r="$r|-mfix-cortex-a53-835769"
    probe "$1" -mllvm -enable-loop-distribute || r="$r|-mllvm -enable-loop-distribute"
    if ! probe "$1" -O3 -flto -fuse-ld=lld; then r="$r|-flto|-fuse-ld=lld|-Wl,-hugetlbfs-align"
    elif ! probe "$1" -fuse-ld=lld -Wl,-hugetlbfs-align; then r="$r|-Wl,-hugetlbfs-align"; fi
    echo "${r#|}"
  }
  RMF=$(rmf_for clang)
  [ -n "$RMF" ] && echo "  note: this clang/linker rejects: $(echo "$RMF" | tr '|' ' ') -> building without them"
  echo "[3/6] Building variants: $VARIANTS ($JOBS compile jobs)"
  for v in $VARIANTS; do
    vb=$(vbase "$v"); tn=$(vtune "$v")
    fl=$(vflags "$vb"); [ "$fl" = "UNKNOWN" ] && { echo "unknown variant $v"; exit 1; }
    d="$WORK/build-$v"
    echo "  - $v ${fl:+($fl)} ${tn:+[tune: $tn]}"
    # The upstream tree ships generated build files (configure, Makefile.in) AND stale build products
    # (a prebuilt ccminer and *.o files). Regenerating with autogen fails on current autoconf, and is
    # not needed, so use the shipped configure as-is but delete every old build product first so nothing
    # stale is linked. configure.sh is upstream's own flag set (clang, lld, -mtune=cortex-a53).
    nn=$(vcc "$v"); CCD=""; GCCB=""; GSUF=""
    if vgcc "$v"; then
      GV=""
      for g in 14 13 12; do have "g++-$g" && have "gcc-$g" && { GV=$g; break; }; done
      if [ -z "$GV" ] && have apt-get; then $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y gcc-12 g++-12 2>&1 | tail -1; have g++-12 && GV=12; fi
      if [ -z "$GV" ]; then gm=$(gcc -dumpversion 2>/dev/null | cut -d. -f1); [ "${gm:-0}" -ge 12 ] 2>/dev/null && GV=""; fi
      if [ -z "$GV" ] && ! { have gcc && [ "$(gcc -dumpversion 2>/dev/null | cut -d. -f1)" -ge 12 ] 2>/dev/null; }; then
        echo "    skipped: needs GCC 12 or newer (this system has $(gcc -dumpversion 2>/dev/null || echo none))"
        VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##"); continue
      fi
      GCCB=1; GSUF="${GV:+-$GV}"
      echo "    compiler: $(gcc${GV:+-$GV} --version | head -1)"
      vpgo "$v" && { echo "    skipped: -pgo is clang-only"; VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##"); continue; }
    fi
    if [ -n "$nn" ]; then
      CCD="/usr/lib/llvm-$nn/bin"
      [ -x "$CCD/clang" ] || { echo "    skipped: clang-$nn not installed"; VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##"); continue; }
      echo "    compiler: $("$CCD/clang" --version | head -1)"
    fi
    # codegen -mllvm options for this variant (needs to know the clang version for the jump table option)
    MO=""; a=$(valign "$v"); [ -n "$a" ] && MO="$a"; jt=$(vjt "$v")
    if [ -n "$jt" ]; then
      cmaj=$("${CCD:+$CCD/}clang" --version 2>/dev/null | grep -o 'version [0-9]*' | head -1 | awk '{print $2}')
      if [ "${cmaj:-0}" -ge 18 ] 2>/dev/null; then MO="$MO -aarch64-min-jump-table-entries=$jt"; else MO="$MO -min-jump-table-entries=$jt"; fi
    fi
    XC=""; XL=""
    if [ -n "$MO" ]; then
      [ -n "$GCCB" ] && { echo "    skipped: -al/-jt are clang options"; VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##"); continue; }
      for o in $MO; do XC="$XC -mllvm $o"; XL="$XL -Wl,-mllvm,$o"; done; XC=${XC# }; XL=${XL# }
      echo "    codegen options: $MO"
    fi
    bld() { # dir extra-compiler-and-linker-flags
      local R="$RMF"; [ -n "$CCD" ] && R=$(rmf_for "$CCD/clang"); [ -n "$GCCB" ] && R=""
      rm -rf "$1"; cp -r "$WORK/src-orig" "$1"
      ( cd "$1" && find . -name '*.o' -delete && rm -f ccminer *.opt.yaml config.status && \
          { if [ -n "$CCD" ]; then sed -i "s#CXX=clang++ CC=clang#CXX=$CCD/clang++ CC=$CCD/clang#" configure.sh; fi; true; } && \
          { if [ -n "$GCCB" ]; then printf '%s\n' 'X="-O3 -ffast-math -mfix-cortex-a53-835769 -D_REENTRANT -falign-functions=16 -fomit-frame-pointer -fpic -pthread -flto=auto -fno-stack-protector -flax-vector-conversions"' \
              "./configure CC=gcc$GSUF CXX=g++$GSUF AR=gcc-ar$GSUF RANLIB=gcc-ranlib$GSUF "'CFLAGS="-finline-functions -march=armv8-a+crypto -mtune=cortex-a53 $X" CXXFLAGS="-funroll-loops -finline-functions -march=armv8-a+crypto -mtune=cortex-a53 $X" LDFLAGS="-flto=auto"' > configure.sh; fi; true; } && \
          { if [ -n "$R" ]; then echo "$R" | tr '|' '\n' | while IFS= read -r f; do sed -i "s# $f##g" configure.sh; done; fi; true; } && \
          { if [ "$tn" = GENERIC ]; then sed -i 's# -mtune=cortex-a53##g' configure.sh; elif [ -n "$tn" ]; then sed -i "s#-mtune=cortex-a53#$tn#g" configure.sh; fi; true; } && \
          { if [ -n "$2" ]; then sed -i "s#^extracflags=\"#extracflags=\"$2 #" configure.sh && sed -i "s#LDFLAGS=\"-v -flto#LDFLAGS=\"-v -flto $2#" configure.sh; fi; true; } && \
          { if [ -n "$XC" ]; then sed -i "s#^extracflags=\"#extracflags=\"$XC #" configure.sh && sed -i "s#LDFLAGS=\"-v -flto#LDFLAGS=\"-v -flto $XL#" configure.sh; fi; true; } && \
          ./configure.sh && make -j"$JOBS" CPPFLAGS="$fl" ) >>"$BUILDLOG" 2>&1
    }
    if vpgo "$v"; then
      PROFDATA=""
      cm=$("${CCD:+$CCD/}clang" --version 2>/dev/null | grep -o 'version [0-9]*' | head -1 | awk '{print $2}')
      for c in ${CCD:+"$CCD/llvm-profdata"} llvm-profdata "llvm-profdata-$cm" "/usr/lib/llvm-$cm/bin/llvm-profdata"; do have "$c" && { PROFDATA="$c"; break; }; [ -x "$c" ] && { PROFDATA="$c"; break; }; done
      [ -z "$PROFDATA" ] && { echo "  !! $v: llvm-profdata not found (install the llvm package); skipping this variant"; VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##"); continue; }
      echo "    instrumented build, then training on this phone (~50 s)..."
      bld "$d-inst" "-fprofile-instr-generate"
      [ -x "$d-inst/ccminer" ] || { echo "BUILD FAILED for $v (instrumented). Last lines of $BUILDLOG:"; tail -25 "$BUILDLOG"; exit 1; }
      PD="$d-prof"; rm -rf "$PD"; mkdir -p "$PD"
      # cover every hashing path: plain loop, two-nonce x2 / sel / sel2 (env overrides of the auto variants)
      for e in "VERUS_LANES=1:15" "VERUS_LANES=2 VERUS_SEL=0:12" "VERUS_LANES=2 VERUS_SEL=1:8" "VERUS_LANES=2 VERUS_SEL=3:12"; do
        env ${e%:*} LLVM_PROFILE_FILE="$PD/%p.profraw" "$d-inst/ccminer" -a verus --benchmark -t 1 --time-limit "${e##*:}" --no-color >/dev/null 2>&1 </dev/null
      done
      "$PROFDATA" merge -o "$PD/verus.profdata" "$PD"/*.profraw >>"$BUILDLOG" 2>&1 || { echo "  !! $v: profile merge failed, see $BUILDLOG"; exit 1; }
      echo "    profile: $(ls "$PD"/*.profraw | wc -l) runs merged with $PROFDATA; optimised build..."
      bld "$d" "-fprofile-use=$PD/verus.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date -Wno-backend-plugin"
    else
      bld "$d" ""
    fi
    if [ -x "$d/ccminer" ] && [ "$d/ccminer" -nt "$d/verus/verus_variant.h" ]; then
      # Prove the right code was linked: the variant name literal must be in the binary.
      case "$vb" in
        baseline) grep -q 'baseline+' "$d/ccminer" && { echo "  !! $v binary contains variant code"; exit 1; } ;;
        *)        grep -q "baseline+$(vmarker "$vb")" "$d/ccminer" || { echo "  !! $v binary lacks the variant marker (stale objects?)"; exit 1; } ;;
      esac
      cp "$d/ccminer" "$BIN/ccminer-$v"
    elif [ -n "$CCD" ] || [ -n "$GCCB" ]; then
      echo "    !! build with this compiler failed; dropping $v. First errors:"; grep -E 'error|Error' "$BUILDLOG" | grep -v conftest | tail -6
      VARIANTS=$(echo " $VARIANTS " | sed "s# $v # #; s#^ ##; s# \$##")
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
  vpgo "$v" && continue   # same source as the variant without -pgo, tested there
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
  if ( cd "$SRC" && clang $CFL -Dharaka512_keyed=haraka512_keyed_base -Dharaka512_keyed_x2=haraka512_keyed_x2_base -c verus/haraka.c -o "$T/hb.o" && \
       clang $CFL $fl -Dharaka512_keyed=haraka512_keyed_var -Dharaka512_keyed_x2=haraka512_keyed_x2_var -c verus/haraka.c -o "$T/hv.o" && \
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
UDD8C6pSAwA=
