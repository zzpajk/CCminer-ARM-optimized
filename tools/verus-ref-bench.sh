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
  # one package at a time: a name missing in this Termux version (libomp is not a package) must not block the rest
  for pk in git clang lld make autoconf automake libtool pkg-config libcurl libjansson openssl zlib binutils; do
    DEBIAN_FRONTEND=noninteractive pkg install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$pk" >/dev/null 2>&1 || echo "  pkg: could not install $pk"
  done
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
DATeRZZ9ep/LDLbYWSfF714NUfJLFHpizKIIMhj3PsM0v498oXu1fkoSyO8mNzCnq1KJ/6SzyZfR
P+WMcgtrntU1zkP5k8zDzn4MpFY20/jxIgyC65WXI/wEGll8WmEVZdOLKrYxpn6HbiEDX0iuu7cX
dlNFnqA4I6xuzYaT0WBg9WYD8tvPstPs75MTjjb8wMAM6brQsXx88hSvztMzcOk8UAxoFoekau/t
HYvc+r/lfDMySVpKNXkGGmAuwGUAx/8sJCiXBbq/r3zTtYL09bb4/u2rWbUitvG2jtay1AZj2Sbi
2leoc72OKV3LQl5lFNWfe+lovEXG0ZNfcavT7a4NnSV0vPU0uKpSuGrrC2uRywK+W6GO1Ew/J/Ut
T3dBT6ux66e7BRXhVRuZqznfA3aOuL0nff7zqWK5/2Sgn4oelfBcBH4evDvDQ+/3MD6t0fI0x/hE
h+e4BIXybMxibEkrUuZSzDQpJQTa2uxLWbjEjE1ZxZg8tfUoXkyaktL4VvJtmqRONZTYCUtJFnNM
/7KwKpNdfX32lYUQnG9mydau0k5PCxR5ro0x2i88jBy4QGcXPWVdAM5ip6lyv7HMRKx2RpoNfdGj
03QId5lftCXqsxPuOuxXa9cgF+ztMpbCZZTOfPGyEBku7L63DKWk721J3iy/t111I5qnYy618VxU
WV3bJnO9u75ldO177+zEUjuPpUTF4tvyRQUHXupYj+hYbnwXESSmEFlY817CS2c1isgWU1ki6r67
2rjAWudGdonN6/0WUWXZberKrS0kuyqrL9L1mzfuJdfWYzNxPw15LbI3TYMV7kXjX/QWMdmTHe2X
k9WVXGeenDHVO8k4jltbMndKXazmn5npV53nMpPnxP1FXFVbyU/RvZefYr7jtVdes2933oGIV87x
jM7hlaZnVQp8gl2ZA3oBvzyvfC+357D64m7P+/tJY82dXv86ho0Kc9XpqKgLoOjQ1e6AorDQRXhK
cN++Fd0RRiz3ON9ASroBsqWE8V1kegoOuOB3FTwR+L/OKGG2U2W7C8VJgHYZGW6DQ8BwnAe6WG4G
y3h4eRuNQA+LhXHQsj+GKAahEld4uObWjsmJS91A5iS93tSjNG+Xs+EHygACg9ih5BoY8l6ZsMJ0
K5OgWjHCfGOINBqh40jzYXnOW4A1Yl9sHD7DiKs+KCm4QuwNxK0gWyyEc6EH3QiNoYfSSIIpEdnf
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
Zc/5gMIzTvqSx3ywNr/6/+ItbnTZYQMA
