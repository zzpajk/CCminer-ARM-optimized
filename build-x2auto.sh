#!/usr/bin/env bash
# build-x2auto.sh - build this ccminer with the "x2auto" Verushash speedup and nothing else added.
#
# x2auto: on out-of-order cores (Mongoose, Cortex-A7x, ...) two nonces are hashed side by side, which was
# measured +19..27% per core on Exynos 8895 and 990; on in-order cores (Cortex-A53/A55) the original
# one-nonce loop is used because two nonces would be slower there. The choice is made per core, at run time.
# No dev fee, no donation code, no hardcoded pool or wallet.
#
# Usage:   bash build-x2auto.sh [-j JOBS]
# Output:  ./ccminer-x2auto   (the source tree itself is left untouched; the build happens in a copy)
# Run:     ./ccminer-x2auto -a verus -o stratum+tcp://YOUR_POOL:PORT -u YOUR_WALLET.WORKER -p x -t 8
# Check:   ./ccminer-x2auto -a verus --benchmark -t 8 --time-limit 20     (prints H/s; Ctrl-C to stop otherwise)
# The banner prints "Verus variant: x2auto" and each thread logs how many nonces per step it uses.

set -u
cd "$(dirname "$0")" || exit 1
SRC=$(pwd); WORK="${VERUS_WORK:-$HOME/ccminer-x2auto-build}"; JOBS=""
while [ $# -gt 0 ]; do case "$1" in -j) JOBS="$2"; shift 2;; *) echo "unknown option: $1"; exit 2;; esac; done
have() { command -v "$1" >/dev/null 2>&1; }
SUDO=""; [ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"

if have pkg; then
  echo "[1/4] Installing build dependencies (Termux)..."
  pkg install -y git clang lld make autoconf automake libtool pkg-config libcurl libjansson openssl zlib binutils libomp 2>&1 | tail -3
elif have apt-get; then
  echo "[1/4] Installing build dependencies (apt; may ask for your sudo password)..."
  $SUDO apt-get update -qq 2>&1 | tail -2
  $SUDO apt-get install -y git clang lld make autoconf automake libtool pkg-config binutils \
      libcurl4-openssl-dev libjansson-dev libssl-dev zlib1g-dev 2>&1 | tail -3
else
  echo "[1/4] Neither pkg nor apt-get found: install clang, lld, make, autotools and libcurl/jansson/openssl/zlib dev packages yourself."
fi
MISSING=""
for c in clang clang++ make; do have "$c" || MISSING="$MISSING $c"; done
for h in curl/curl.h jansson.h openssl/ssl.h zlib.h; do
  printf '#include <%s>\n' "$h" | clang -E -x c - >/dev/null 2>&1 || MISSING="$MISSING header:$h"
done
[ -n "$MISSING" ] && { echo "Missing:$MISSING - install them and run again."; exit 1; }
[ -z "$JOBS" ] && { JOBS=$(nproc 2>/dev/null || echo 2); [ "$JOBS" -gt 4 ] && JOBS=4; }

# Older clang versions (Ubuntu 20.04 ships clang 10) reject some flags in configure.sh; drop what is rejected.
echo "[2/4] Checking which compiler flags this clang accepts..."
mkdir -p "$WORK"; echo 'int main(void){return 0;}' > "$WORK/probe.c"
probe() { clang -x c "$WORK/probe.c" "$@" -o "$WORK/probe.out" >/dev/null 2>&1; }
RMF=""
probe -ffinite-loops || RMF="$RMF|-ffinite-loops"
probe -mfix-cortex-a53-835769 || RMF="$RMF|-mfix-cortex-a53-835769"
probe -mllvm -enable-loop-distribute || RMF="$RMF|-mllvm -enable-loop-distribute"
if ! probe -O3 -flto -fuse-ld=lld; then RMF="$RMF|-flto|-fuse-ld=lld|-Wl,-hugetlbfs-align"
elif ! probe -fuse-ld=lld -Wl,-hugetlbfs-align; then RMF="$RMF|-Wl,-hugetlbfs-align"; fi
RMF=${RMF#|}
[ -n "$RMF" ] && echo "  not supported here, building without: $(echo "$RMF" | tr '|' ' ')"

echo "[3/4] Building (log: $WORK/build.log)..."
B="$WORK/build"; rm -rf "$B"; mkdir -p "$B"
# copy the tree without stale build products shipped in the repository
( cd "$SRC" && tar --exclude=.git --exclude='*.o' --exclude='*.opt.yaml' --exclude=ccminer --exclude='ccminer-x2auto' -cf - . ) | ( cd "$B" && tar -xf - )
( cd "$B" && rm -f config.status && \
  { if [ -n "$RMF" ]; then echo "$RMF" | tr '|' '\n' | while IFS= read -r f; do sed -i "s# $f##g" configure.sh; done; fi; true; } && \
  ./configure.sh && make -j"$JOBS" CPPFLAGS="-DVERUS_X2 -DVERUS_AUTO" ) >"$WORK/build.log" 2>&1
if [ ! -x "$B/ccminer" ] || ! grep -q 'baseline+x2auto' "$B/ccminer"; then
  echo "BUILD FAILED. Last lines of $WORK/build.log:"; tail -25 "$WORK/build.log"; exit 1
fi
cp "$B/ccminer" "$SRC/ccminer-x2auto"
echo "[4/4] Done: $SRC/ccminer-x2auto"
echo "Run with your own pool and wallet, e.g.:"
echo "  ./ccminer-x2auto -a verus -o stratum+tcp://YOUR_POOL:PORT -u YOUR_WALLET.WORKER -p x -t $(nproc 2>/dev/null || echo 8)"
