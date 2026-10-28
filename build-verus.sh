#!/usr/bin/env bash
# build-verus.sh - one-step build of this ccminer with the fastest measured Verushash code for ARM phones.
#
# What it builds (variant "x2percore+pristine", chosen per core at run time):
#   in-order cores (Cortex-A53/A55/A510, Kryo Silver)  the original one-nonce loop, with the key restored from
#                                                       a pristine copy instead of a per-round journal
#   Mongoose M1/M2, Cortex-A73                        two nonces hashed side by side
#   every other big core (Mongoose M3-M5, A75-A78, X1)  two nonces side by side + branch-free choices (in cases
#                                                       0x14 and 0x18, and except on the A75 also in 0x0c)
# Compiler: clang 17 when it can be installed (measured +2-3% over clang 10/14 on 5 phones, GCC slower);
# otherwise the system clang. With clang 18 or newer (e.g. Termux) the script restores jump tables for small
# switches (LLVM 18 stopped using them below 13 cases on AArch64, which turns the hash's 8-way case switch into
# a tree of unpredictable branches: -4..-5% on the phones, measured both ways on a Galaxy S9).
# Measured on Exynos phones (all cores, vs the unmodified miner): S8 +13%, S9 +20%, S10 +21%, S20 +17..19%,
# S21 +12%, before the clang 17 gain. No dev fee, no donation code, no hardcoded pool or wallet.
#
# Usage:   bash build-verus.sh [-j JOBS] [--system-clang]
# Output:  ./ccminer-verus   (the source tree itself is left untouched; the build happens in a copy)
# Run:     ./ccminer-verus -a verus -o stratum+tcp://YOUR_POOL:PORT -u YOUR_WALLET.WORKER -p x -t 8
# Check:   ./ccminer-verus -a verus --benchmark -t 8 --time-limit 20
# The banner prints "Verus variant: x2percore+pristine"; each thread logs which path its core uses.
#
# On apt systems without clang 17 in the distribution (Ubuntu 20.04/22.04) the script adds LLVM's own
# repository (apt.llvm.org, llvm-toolchain-<release>-17) to install it next to the system clang. Use
# --system-clang to skip that.

set -u
cd "$(dirname "$0")" || exit 1
SRC=$(pwd); WORK="${VERUS_WORK:-$HOME/ccminer-verus-build}"; JOBS=""; WANT=17; SYSCLANG=0
while [ $# -gt 0 ]; do case "$1" in -j) JOBS="$2"; shift 2;; --system-clang) SYSCLANG=1; shift;; *) echo "unknown option: $1"; exit 2;; esac; done
have() { command -v "$1" >/dev/null 2>&1; }
SUDO=""; [ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"

if have pkg && [ -d /data/data/com.termux ]; then
  echo "[1/5] Installing build dependencies (Termux)..."
  pkg install -y git clang lld make autoconf automake libtool pkg-config libcurl libjansson openssl zlib binutils libomp 2>&1 | tail -3
  SYSCLANG=1   # Termux ships one clang version
elif have apt-get; then
  echo "[1/5] Installing build dependencies (apt; may ask for your sudo password)..."
  $SUDO apt-get -o DPkg::Lock::Timeout=600 update -qq 2>&1 | tail -2
  $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y git clang lld make autoconf automake libtool pkg-config binutils \
      libcurl4-openssl-dev libjansson-dev libssl-dev zlib1g-dev 2>&1 | tail -3
else
  echo "[1/5] Neither pkg nor apt-get found: install clang, lld, make, autotools and libcurl/jansson/openssl/zlib dev packages yourself."
  SYSCLANG=1
fi

CCD=""
if [ "$SYSCLANG" -eq 0 ]; then
  echo "[2/5] Getting clang $WANT..."
  if [ ! -x "/usr/lib/llvm-$WANT/bin/clang" ] || [ ! -x "/usr/lib/llvm-$WANT/bin/ld.lld" ]; then
    $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y "clang-$WANT" "lld-$WANT" >/dev/null 2>&1
    if [ ! -x "/usr/lib/llvm-$WANT/bin/clang" ]; then
      cn=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")
      if [ -n "$cn" ]; then
        echo "  adding apt.llvm.org (llvm-toolchain-$cn-$WANT)"
        key="/etc/apt/trusted.gpg.d/apt.llvm.org.asc"
        if [ ! -s "$key" ]; then
          if have curl; then curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | $SUDO tee "$key" >/dev/null
          elif have wget; then wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | $SUDO tee "$key" >/dev/null; fi
        fi
        echo "deb http://apt.llvm.org/$cn/ llvm-toolchain-$cn-$WANT main" | $SUDO tee "/etc/apt/sources.list.d/llvm-$WANT.list" >/dev/null
        $SUDO apt-get -o DPkg::Lock::Timeout=600 update -qq 2>&1 | tail -2
        $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y "clang-$WANT" "lld-$WANT" 2>&1 | tail -2
      fi
    fi
  fi
  if [ -x "/usr/lib/llvm-$WANT/bin/clang" ] && [ -x "/usr/lib/llvm-$WANT/bin/ld.lld" ]; then CCD="/usr/lib/llvm-$WANT/bin"
  else echo "  clang $WANT not available; using the system clang"; fi
else
  echo "[2/5] Using the system clang"
fi
CLANG="${CCD:+$CCD/}clang"
echo "  compiler: $("$CLANG" --version 2>/dev/null | head -1)"

MISSING=""
for c in "$CLANG" make; do have "$c" || [ -x "$c" ] || MISSING="$MISSING $c"; done
for h in curl/curl.h jansson.h openssl/ssl.h zlib.h; do
  printf '#include <%s>\n' "$h" | "$CLANG" -E -x c - >/dev/null 2>&1 || MISSING="$MISSING header:$h"
done
[ -n "$MISSING" ] && { echo "Missing:$MISSING - install them and run again."; exit 1; }
[ -z "$JOBS" ] && { JOBS=$(nproc 2>/dev/null || echo 2); [ "$JOBS" -gt 4 ] && JOBS=4; }

# Older clang versions reject some flags in configure.sh; drop what this compiler rejects.
echo "[3/5] Checking which compiler flags this clang accepts..."
mkdir -p "$WORK"; echo 'int main(void){return 0;}' > "$WORK/probe.c"
probe() { "$CLANG" -x c "$WORK/probe.c" "$@" -o "$WORK/probe.out" >/dev/null 2>&1; }
RMF=""
probe -ffinite-loops || RMF="$RMF|-ffinite-loops"
probe -mfix-cortex-a53-835769 || RMF="$RMF|-mfix-cortex-a53-835769"
probe -mllvm -enable-loop-distribute || RMF="$RMF|-mllvm -enable-loop-distribute"
if ! probe -O3 -flto -fuse-ld=lld; then RMF="$RMF|-flto|-fuse-ld=lld|-Wl,-hugetlbfs-align"
elif ! probe -fuse-ld=lld -Wl,-hugetlbfs-align; then RMF="$RMF|-Wl,-hugetlbfs-align"; fi
RMF=${RMF#|}
CMAJ=$("$CLANG" --version 2>/dev/null | grep -o 'version [0-9]*' | head -1 | awk '{print $2}')
JT=""
if [ "${CMAJ:-0}" -ge 18 ] 2>/dev/null; then
  JT="-aarch64-min-jump-table-entries=4"
  probe -mllvm "$JT" || JT=""
  [ -n "$JT" ] && echo "  clang $CMAJ: restoring jump tables for small switches ($JT)"
fi
[ -n "$RMF" ] && echo "  not supported here, building without: $(echo "$RMF" | tr '|' ' ')"

echo "[4/5] Building (log: $WORK/build.log)..."
B="$WORK/build"; rm -rf "$B"; mkdir -p "$B"
# copy the tree without stale build products shipped in the repository
( cd "$SRC" && tar --exclude=.git --exclude='*.o' --exclude='*.opt.yaml' --exclude=ccminer --exclude='ccminer-verus' -cf - . ) | ( cd "$B" && tar -xf - )
( cd "$B" && rm -f config.status && \
  { if [ -n "$CCD" ]; then sed -i "s#CXX=clang++ CC=clang#CXX=$CCD/clang++ CC=$CCD/clang#" configure.sh; fi; true; } && \
  { if [ -n "$RMF" ]; then echo "$RMF" | tr '|' '\n' | while IFS= read -r f; do sed -i "s# $f##g" configure.sh; done; fi; true; } && \
  { if [ -n "$JT" ]; then sed -i "s#^extracflags=\"#extracflags=\"-mllvm $JT #" configure.sh; sed -i "s#LDFLAGS=\"-v -flto#LDFLAGS=\"-v -flto -Wl,-mllvm,$JT#" configure.sh; fi; true; } && \
  sh ./configure.sh && make -j"$JOBS" CPPFLAGS="-DVERUS_X2 -DVERUS_AUTO -DVERUS_PERCORE -DVERUS_PRISTINE" ) >"$WORK/build.log" 2>&1
if [ ! -x "$B/ccminer" ] || ! grep -q 'baseline+x2percore+pristine' "$B/ccminer"; then
  echo "BUILD FAILED. Last lines of $WORK/build.log:"; tail -25 "$WORK/build.log"; exit 1
fi
cp "$B/ccminer" "$SRC/ccminer-verus"
echo "[5/5] Done: $SRC/ccminer-verus"
echo "Quick check (about 20 s):  ./ccminer-verus -a verus --benchmark -t $(nproc 2>/dev/null || echo 8) --time-limit 20"
echo "Mine with your own pool and wallet, e.g.:"
echo "  ./ccminer-verus -a verus -o stratum+tcp://YOUR_POOL:PORT -u YOUR_WALLET.WORKER -p x -t $(nproc 2>/dev/null || echo 8)"
