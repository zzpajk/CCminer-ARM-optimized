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
#                to 16/32/64 bytes; -jtN sets the minimum case count for a jump table (e.g. x2percorep-jt4-c18);
#                -np builds without -fpic (order: name-tXX-alN-jtN-np-cNN-gcc-pgo).
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
vbase() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-np}"; b="${b%-jt[0-9]*}"; b="${b%-al[0-9]}"; echo "${b%%-t*}"; }
# -np: build without -fpic (the miner is an executable; position-independent code only adds GOT indirections)
vnp() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; case "$b" in *-np) return 0;; esac; return 1; }
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
valign() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-np}"; b="${b%-jt[0-9]*}"; case "$b" in *-al[0-9]) echo "-align-all-nofallthru-blocks=${b##*-al}";; *) echo "";; esac; }
vjt() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-np}"; case "$b" in *-jt[0-9]*) echo "${b##*-jt}";; *) echo "";; esac; }
vtune() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; b="${b%-np}"; b="${b%-jt[0-9]*}"; case "${b%-al[0-9]}" in *-t55) echo "-mtune=cortex-a55";; *-t76) echo "-mtune=cortex-a76";; *-tgen) echo "GENERIC";; *) echo "";; esac; }
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
          { if vnp "$v"; then sed -i "s# -fpic##g" configure.sh; fi; true; } && \
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
6qQBw1O00nGVNOzNR/8fp0WlRA5UAwA=
