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
