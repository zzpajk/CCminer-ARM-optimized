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
etYHDE857c8f9WFvPvr/D6vVkOMmAwA=
