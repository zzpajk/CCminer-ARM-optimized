#!/usr/bin/env bash
# userland-install.sh - set up UserLAnd (Ubuntu / Debian on Android) and build (or update) the Verus ccminer
# from this fork. Also works on any Debian / Ubuntu ARM64 system (Raspberry Pi OS 64-bit, Armbian, ...).
#
#   sudo apt-get update && sudo apt-get install -y curl
#   curl -fsSL https://raw.githubusercontent.com/zzpajk/CCminer-ARM-optimized/variants/tools/userland-install.sh -o ~/userland-install.sh
#   bash ~/userland-install.sh
#
# 1. installs git and screen
# 2. clones github.com/zzpajk/CCminer-ARM-optimized (branch variants) into ~/ccminer, or updates it
# 3. builds with build-verus.sh (installs the compiler and libraries it needs) -> ~/ccminer/ccminer-verus
#    (the previous binary is kept as ccminer-verus.old)
# 4. writes verus.conf (only if missing), start-ccminer.sh and stop-ccminer.sh into the same folder
# Run it again at any time to update and rebuild. Options:
#   --no-build     only install packages and update the source
#   -b BRANCH      build another branch (default: variants)
# Nothing is started, no pool or wallet is configured.
set -u
REPO=https://github.com/zzpajk/CCminer-ARM-optimized.git
BRANCH=variants; DIR="$HOME/ccminer"; BUILD=1
while [ $# -gt 0 ]; do case "$1" in
	--no-build) BUILD=0; shift;;
	-b) BRANCH="$2"; shift 2;;
	*) echo "unknown option: $1"; exit 2;;
esac; done
command -v apt-get >/dev/null 2>&1 || { echo "This script needs apt-get (UserLAnd Ubuntu/Debian). In Termux use tools/termux-install.sh instead."; exit 1; }
[ -d /data/data/com.termux ] && command -v pkg >/dev/null 2>&1 && { echo "This is Termux: use tools/termux-install.sh instead."; exit 1; }
SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

echo "[1/4] Installing git and screen (may ask for your password)..."
$SUDO apt-get -o DPkg::Lock::Timeout=600 update -qq 2>&1 | tail -2
DEBIAN_FRONTEND=noninteractive $SUDO apt-get -o DPkg::Lock::Timeout=600 install -y git screen ca-certificates 2>&1 | tail -2
command -v git >/dev/null 2>&1 || { echo "git could not be installed"; exit 1; }

echo "[2/4] Getting the source ($BRANCH)..."
if [ -d "$DIR/.git" ]; then
	git -C "$DIR" fetch -q --depth 1 origin "$BRANCH" || { echo "git fetch failed (network?)"; exit 1; }
	git -C "$DIR" checkout -q -B "$BRANCH" FETCH_HEAD && git -C "$DIR" reset -q --hard FETCH_HEAD
elif [ -e "$DIR" ]; then
	echo "$DIR exists but is not a copy of this repository: move it away and run again"; exit 1
else
	git clone -q --depth 1 -b "$BRANCH" "$REPO" "$DIR" || { echo "git clone failed (network?)"; exit 1; }
fi
echo "  commit $(git -C "$DIR" log -1 --format='%h %cd %s' --date=short | cut -c1-100)"

echo "[3/4] Writing verus.conf, start-ccminer.sh, stop-ccminer.sh in $DIR..."
if [ ! -f "$DIR/verus.conf" ]; then
cat > "$DIR/verus.conf" <<'CONF_END'
{
  "pools": [
    {
      "name": "verus.io",
      "url": "stratum+tcp://pool.verus.io:9998",
      "timeout": 150
    }
  ],
  "user": "i81XL8ZpuCo9jmWLv5L5ikdxrGuHrrpQLz.unconfigeredminer",
  "algo": "verus",
  "threads": 8,
  "cpu-priority": 1,
  "retry-pause": 5,
  "api-allow": "0/0",
  "api-bind": "0.0.0.0:4068"
}
CONF_END
else echo "  verus.conf exists, left unchanged"; fi
cat > "$DIR/start-ccminer.sh" <<'START_END'
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
# end an existing screen session named ccminer
screen -S ccminer -X quit 2>/dev/null
# remove dead screens
screen -wipe >/dev/null 2>&1
# create a new detached session named ccminer
screen -dmS ccminer
# run the miner in it
screen -S ccminer -X stuff "$D/ccminer-verus -c $D/verus.conf -b --api-remote\n"
START_END
cat > "$DIR/stop-ccminer.sh" <<'STOP_END'
#!/bin/sh
# end the screen session named ccminer (stops the miner)
screen -S ccminer -X quit
# remove dead screens
screen -wipe >/dev/null 2>&1
STOP_END
chmod +x "$DIR/start-ccminer.sh" "$DIR/stop-ccminer.sh"

[ "$BUILD" = 1 ] || { echo "Source is in $DIR (not built: --no-build)."; exit 0; }
echo "[4/4] Building (several minutes)..."
[ -x "$DIR/ccminer-verus" ] && cp -f "$DIR/ccminer-verus" "$DIR/ccminer-verus.old"
if bash "$DIR/build-verus.sh"; then
	echo
	echo "Binary: $DIR/ccminer-verus  (built from $(git -C "$DIR" rev-parse --short HEAD))"
	echo "Benchmark: $DIR/ccminer-verus -a verus --benchmark -t $(grep -c ^processor /proc/cpuinfo) --time-limit 20"
	echo "Next: put your pool and wallet in $DIR/verus.conf, then"
	echo "Start: $DIR/start-ccminer.sh   Stop: $DIR/stop-ccminer.sh   Watch: screen -r ccminer (detach: Ctrl-A D)"
else
	[ -x "$DIR/ccminer-verus.old" ] && echo "Build failed; the previous binary is still at $DIR/ccminer-verus.old"
	exit 1
fi
