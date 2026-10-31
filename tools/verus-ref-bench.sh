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
