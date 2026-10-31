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
