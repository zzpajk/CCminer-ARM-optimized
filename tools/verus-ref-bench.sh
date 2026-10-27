#!/usr/bin/env bash
# verus-ref-bench.sh v4.4 (Termux, or Ubuntu/Debian arm64 such as UserLAnd) - build named Verushash variants of Oink70/CCminer-ARM-optimized,
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
vbase() { local b="${1%-pgo}"; b="${b%-gcc}"; b="${b%-c[0-9]*}"; echo "${b%%-t*}"; }
vgcc() { case "${1%-pgo}" in *-gcc) return 0;; esac; return 1; }
vcc() { local b="${1%-pgo}"; case "$b" in *-c[0-9]*) echo "${b##*-c}";; *) echo "";; esac; }
vpgo() { case "$1" in *-pgo) return 0;; esac; return 1; }
vtune() { local b="${1%-pgo}"; case "${b%-c[0-9]*}" in *-t55) echo "-mtune=cortex-a55";; *-t76) echo "-mtune=cortex-a76";; *-tgen) echo "GENERIC";; *) echo "";; esac; }
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
