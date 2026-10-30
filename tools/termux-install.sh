#!/data/data/com.termux/files/usr/bin/bash
# termux-install.sh - set up Termux and build (or update) the newest Verus ccminer from this fork.
#
#   curl -fsSL https://raw.githubusercontent.com/zzpajk/CCminer-ARM-optimized/variants/tools/termux-install.sh -o ~/termux-install.sh
#   bash ~/termux-install.sh
#
# 1. updates Termux packages (answers all prompts, keeps existing config files)
# 2. installs git and the build dependencies
# 3. clones github.com/zzpajk/CCminer-ARM-optimized (branch variants) into ~/ccminer-arm-optimized,
#    or, if it is already there, updates it to the newest commit
# 4. builds with build-verus.sh -> ~/ccminer-arm-optimized/ccminer-verus
#    (the previous binary is kept as ccminer-verus.old)
# Run it again at any time to update and rebuild. Options:
#   --no-upgrade   skip "pkg upgrade" (faster when the packages were updated recently)
#   --no-build     only install packages and update the source
#   -b BRANCH      build another branch (default: variants)
# Nothing is started, no pool or wallet is configured.
set -u
REPO=https://github.com/zzpajk/CCminer-ARM-optimized.git
BRANCH=variants; DIR="$HOME/ccminer-arm-optimized"; UPGRADE=1; BUILD=1
while [ $# -gt 0 ]; do case "$1" in
	--no-upgrade) UPGRADE=0; shift;;
	--no-build) BUILD=0; shift;;
	-b) BRANCH="$2"; shift 2;;
	*) echo "unknown option: $1"; exit 2;;
esac; done

if [ ! -d /data/data/com.termux ] || ! command -v pkg >/dev/null 2>&1; then
	echo "This script is for Termux. In UserLAnd/Ubuntu run build-verus.sh from the repository instead."; exit 1
fi
export DEBIAN_FRONTEND=noninteractive
APTOPT=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[1/4] Updating Termux packages..."
if [ "$UPGRADE" = 1 ]; then
	pkg update "${APTOPT[@]}" 2>&1 | tail -2
	pkg upgrade "${APTOPT[@]}" 2>&1 | tail -2
else
	pkg update "${APTOPT[@]}" >/dev/null 2>&1
fi

echo "[2/4] Installing git and build dependencies..."
for pk in git clang lld make autoconf automake libtool pkg-config libcurl libjansson openssl zlib binutils; do
	pkg install "${APTOPT[@]}" "$pk" >/dev/null 2>&1 || echo "  could not install $pk"
done
command -v git >/dev/null 2>&1 || { echo "git is missing; check your Termux mirror (termux-change-repo) and run again."; exit 1; }

echo "[3/4] Getting the source ($BRANCH)..."
if [ -d "$DIR/.git" ]; then
	git -C "$DIR" fetch -q --depth 1 origin "$BRANCH" || { echo "git fetch failed (network?)"; exit 1; }
	git -C "$DIR" checkout -q -B "$BRANCH" FETCH_HEAD && git -C "$DIR" reset -q --hard FETCH_HEAD
else
	git clone -q --depth 1 -b "$BRANCH" "$REPO" "$DIR" || { echo "git clone failed (network?)"; exit 1; }
fi
echo "  commit $(git -C "$DIR" log -1 --format='%h %cd %s' --date=short | cut -c1-100)"

[ "$BUILD" = 1 ] || { echo "Source is in $DIR (not built: --no-build)."; exit 0; }
echo "[4/4] Building (several minutes)..."
[ -x "$DIR/ccminer-verus" ] && cp -f "$DIR/ccminer-verus" "$DIR/ccminer-verus.old"
if bash "$DIR/build-verus.sh"; then
	echo
	echo "Binary: $DIR/ccminer-verus  (built from $(git -C "$DIR" rev-parse --short HEAD))"
	echo "Benchmark: $DIR/ccminer-verus -a verus --benchmark -t $(grep -c ^processor /proc/cpuinfo) --time-limit 20"
	echo "Tip: with root, su -c 'echo 0-7 > /dev/cpuset/foreground/cpus' lets Termux use all 8 CPUs in the background."
else
	[ -x "$DIR/ccminer-verus.old" ] && echo "Build failed; the previous binary is still at $DIR/ccminer-verus.old"
	exit 1
fi
