#!/usr/bin/env bash
# phone-led.sh COLOR|off [steady|blink|find|quietfind] - light the notification LED so a phone can be found physically.
# COLOR: cyan, magenta, red, green, blue, white, or a hex RGB like 00ffff. Tries the Samsung sec LED
# interface (/sys/class/sec/led) and the generic /sys/class/leds/{red,green,blue,led_r,...}, first directly,
# then through su (needs a rooted phone; inside a proot userland the direct writes normally fail).
# MODE: steady (default), blink (500 ms on/off), find (blink + cycling colours + torch, vibration, max volume,
# ringtone and spoken "here I am" via Termux:API for ~45 s; touches volume and the torch as well),
# quietfind (the same without any sound: LED colours, torch and vibration only; volume untouched).
# Prints what it found and what worked.
set -u
c="${1:-cyan}"
mode="${2:-steady}"
quiet=0; [ "$mode" = quietfind ] && { mode=find; quiet=1; }
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
	elif [ "$mode" = steady ]; then w /sys/class/sec/led/led_blink "0x$rgb 1000 0" && ok=1
	else w /sys/class/sec/led/led_blink "0x$rgb 500 500" && ok=1; fi
fi
# generic per-colour LEDs
for set in "red green blue" "led_r led_g led_b" "R G B"; do
	set -- $set
	[ -e "/sys/class/leds/$1/brightness" ] || continue
	echo "== /sys/class/leds/$1,$2,$3"
	w "/sys/class/leds/$1/brightness" $r && w "/sys/class/leds/$2/brightness" $g && w "/sys/class/leds/$3/brightness" $b && ok=1
done
[ $ok = 1 ] && echo "RESULT: LED set to $c" || echo "RESULT: could not set the LED (no writable LED file; root via su is needed)"

[ "$mode" = find ] || exit 0
echo "== find mode"
T() { timeout 8 "$@" </dev/null >/dev/null 2>&1; }
have() { command -v "$1" >/dev/null 2>&1; }
for x in termux-torch termux-vibrate termux-tts-speak termux-media-player termux-volume; do have $x && echo "  have $x" || echo "  missing $x (install Termux:API app + pkg termux-api)"; done
suc() { [ -n "$SU" ] && timeout 10 "$SU" -c "$1" </dev/null >/dev/null 2>&1; }
suc "input keyevent KEYCODE_WAKEUP" && echo "  screen wake sent"
[ $quiet = 1 ] && echo "  quiet: no volume change, no sound"
[ $quiet = 1 ] || for st in 3 4 5; do suc "media volume --stream $st --set 15" || suc "cmd media_session volume --stream $st --set 15"; done
[ $quiet = 0 ] && have termux-volume && { T termux-volume music 15; T termux-volume alarm 7; T termux-volume ring 7; }
snd=$(ls /system/media/audio/ringtones/*.ogg /system/media/audio/alarms/*.ogg 2>/dev/null | head -1)
echo "  sound file: ${snd:-none}"
[ $quiet = 0 ] && [ -n "$snd" ] && have termux-media-player && T termux-media-player play "$snd"
end=$((SECONDS+45)); n=0
while [ $SECONDS -lt $end ]; do
	cols=(ff0000 00ff00 0000ff ffffff ff00ff 00ffff); col=${cols[$((n%6))]}
	[ -d /sys/class/sec/led ] && w /sys/class/sec/led/led_blink "0x$col 300 300" >/dev/null
	have termux-torch && T termux-torch on
	have termux-vibrate && T termux-vibrate -d 700 -f
	[ $quiet = 0 ] && [ $((n%4)) = 0 ] && have termux-tts-speak && T termux-tts-speak -s ALARM "Here I am. Here I am."
	sleep 1.2; have termux-torch && T termux-torch off; sleep 0.8; n=$((n+1))
done
have termux-torch && T termux-torch off
[ $quiet = 0 ] && have termux-media-player && T termux-media-player stop
[ "$rgb" != 000000 ] && [ -d /sys/class/sec/led ] && w /sys/class/sec/led/led_blink "0x$rgb 500 500" >/dev/null
echo "RESULT: find mode ran $n cycles"
