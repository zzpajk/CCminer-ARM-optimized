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
