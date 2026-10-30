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
  # benchmarks never touch a pool: blank the sample pool/wallet in ccminer.conf here (the fork's own copy has real values)
  sed -i 's#"url" *: *"[^"]*"#"url" : "stratum+tcp://YOUR_POOL_HOST:PORT"#; s#"user" *: *"[^"]*"#"user" : "YOUR_WALLET.YOUR_WORKER"#' "$WORK/src-orig/ccminer.conf"

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
