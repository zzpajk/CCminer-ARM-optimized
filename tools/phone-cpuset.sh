#!/usr/bin/env bash
# phone-cpuset.sh show|widen|restore - inspect or change Android's cpuset for "foreground" apps.
# Android puts an app that is not on screen (e.g. Termux holding a wake lock) into /dev/cpuset/foreground,
# which on Samsung phones leaves out a CPU (0-2,4-7 on an Exynos with 8 cores). "widen" writes all CPUs into
# it (needs Android root: su from Magisk/SuperSU); "restore" writes back the value saved by the first widen.
# The change lasts until reboot (or until the system rewrites it). Touches nothing but that one cpuset file.
set -u
act="${1:-show}"
F=/dev/cpuset/foreground/cpus
SAVE="$HOME/.verus-cpuset-foreground.orig"
SU=""
for s in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /data/adb/magisk/su; do [ -x "$s" ] && { SU=$s; break; }; done
show() {
	echo "this process: allowed cpus $(grep -m1 Cpus_allowed_list /proc/self/status | awk '{print $2}'), cpuset $(cat /proc/self/cpuset 2>/dev/null)"
	for g in top-app foreground background system-background restricted; do
		[ -r /dev/cpuset/$g/cpus ] && echo "  /dev/cpuset/$g/cpus = $(cat /dev/cpuset/$g/cpus)"
	done
	echo "su: ${SU:-none found}"
}
case "$act" in
show) show;;
widen)
	[ -n "$SU" ] || { echo "no Android su found: root needed"; show; exit 1; }
	all=$(cat /sys/devices/system/cpu/present 2>/dev/null); [ -n "$all" ] || all="0-$(( $(grep -c ^processor /proc/cpuinfo) - 1 ))"
	[ -f "$SAVE" ] || cat "$F" > "$SAVE"
	if timeout 15 "$SU" -c "echo $all > $F" </dev/null; then echo "foreground cpuset set to $all (was $(cat "$SAVE"))"; else echo "su write failed"; fi
	show;;
restore)
	[ -n "$SU" ] || { echo "no Android su found"; exit 1; }
	[ -f "$SAVE" ] || { echo "nothing saved"; show; exit 0; }
	v=$(cat "$SAVE")
	timeout 15 "$SU" -c "echo $v > $F" </dev/null && rm -f "$SAVE" && echo "foreground cpuset restored to $v"
	show;;
*) echo "usage: $0 show|widen|restore"; exit 2;;
esac
