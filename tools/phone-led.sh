#!/usr/bin/env bash
# phone-led.sh COLOR|off - light the notification LED so a phone can be found physically.
# COLOR: cyan, magenta, red, green, blue, white, or a hex RGB like 00ffff. Tries the Samsung sec LED
# interface (/sys/class/sec/led) and the generic /sys/class/leds/{red,green,blue,led_r,...}, first directly,
# then through su (needs a rooted phone; inside a proot userland the direct writes normally fail).
# Prints what it found and what worked. Touches nothing but LED files.
set -u
c="${1:-cyan}"
case "$c" in cyan) rgb=00ffff;; magenta) rgb=ff00ff;; red) rgb=ff0000;; green) rgb=00ff00;; blue) rgb=0000ff;;
	white) rgb=ffffff;; off) rgb=000000;; [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) rgb=$c;;
	*) echo "unknown colour $c"; exit 2;; esac
r=$((16#${rgb:0:2})); g=$((16#${rgb:2:2})); b=$((16#${rgb:4:2}))
echo "colour $c = #$rgb (r=$r g=$g b=$b); uid=$(id -u)"
echo "== LED files"; ls -d /sys/class/sec/led/* /sys/class/leds/* 2>&1 | head -40
SU=""
# only Android's root su (Magisk/SuperSU locations); the userland's own /bin/su would ask for a password
for s in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /data/adb/magisk/su; do [ -x "$s" ] && { SU=$s; break; }; done
echo "su: ${SU:-none found}"
w() { # file value -> 0 if written
	[ -e "$1" ] || return 1
	if echo "$2" > "$1" 2>/dev/null; then echo "  wrote $2 > $1"; return 0; fi
	if [ -n "$SU" ] && timeout 10 "$SU" -c "echo '$2' > '$1'" </dev/null 2>/dev/null; then echo "  wrote $2 > $1 (su)"; return 0; fi
	echo "  cannot write $1"; return 1
}
ok=0
# Samsung: led_blink takes "0xRRGGBB on_ms off_ms" (0 0 off = steady), led_pattern 0 clears patterns
if [ -d /sys/class/sec/led ]; then
	echo "== Samsung sec LED"
	w /sys/class/sec/led/led_pattern 0
	if [ "$rgb" = 000000 ]; then w /sys/class/sec/led/led_blink "0x000000 0 0" && ok=1
	else w /sys/class/sec/led/led_blink "0x$rgb 1000 0" && ok=1; fi
fi
# generic per-colour LEDs
for set in "red green blue" "led_r led_g led_b" "R G B"; do
	set -- $set
	[ -e "/sys/class/leds/$1/brightness" ] || continue
	echo "== /sys/class/leds/$1,$2,$3"
	w "/sys/class/leds/$1/brightness" $r && w "/sys/class/leds/$2/brightness" $g && w "/sys/class/leds/$3/brightness" $b && ok=1
done
[ $ok = 1 ] && echo "RESULT: LED set to $c" || echo "RESULT: could not set the LED (no writable LED file; root via su is needed)"
