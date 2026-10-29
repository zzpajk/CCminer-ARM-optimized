#!/usr/bin/env bash
# phone-usb.sh [snapshot|watch SECONDS] - read-only USB / USB-C role diagnostics for a rooted phone.
# snapshot: port role, Samsung cable type, enumerated USB devices (with vendor names), dumpsys usb,
#           Type-C/CCIC sysfs, network interfaces and the USB-related kernel log.
# kernel:   kernel version, module support/signing, loaded modules, build props and the full kernel config
#           (what is needed to build matching driver modules).
# force-source N: TEMPORARILY writes "source" to /sys/class/typec/port0/port_type (phone acts as power source
#           and USB host only), watches N s (max 300), lists any USB devices / interfaces that appear, then restores
#           the original port_type (also on exit/kill). The only mode that changes anything.
# watch N:  samples the role / cable type / device list every 2 s for N seconds (max 600) and prints
#           every change, so someone can replug or flip a cable and see what the phone makes of it.
# Changes nothing: only reads files, dmesg and dumpsys (through su).
set -u
mode="${1:-snapshot}"; secs="${2:-120}"
case "$secs" in ''|*[!0-9]*) secs=120;; esac; [ "$secs" -gt 600 ] && secs=600
SU=""
for s in /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su /data/adb/magisk/su; do [ -x "$s" ] && { SU=$s; break; }; done
[ -n "$SU" ] || { echo "no su found; these checks need root"; exit 1; }
R() { timeout 20 "$SU" -c "$1" </dev/null 2>&1; }
vname() { case "$1" in 0bda) echo Realtek;; 0b95) echo ASIX;; 2109) echo "VIA Labs";; 05e3) echo Genesys;; 046d) echo Logitech;;
	1a40) echo Terminus;; 0424) echo Microchip/SMSC;; 2357) echo TP-Link;; 0fe6) echo "ICS/Kontron (CDC)";; 1d6b) echo "Linux root hub";;
	04e8) echo Samsung;; 17ef) echo Lenovo;; 13b1) echo Linksys;; 0451) echo TI;; *) echo "?";; esac; }
state() { # one line: cable, port role, usb device ids
	local cab role devs
	cab=$(R 'dmesg | grep sec_bat_monitor_work | tail -1' | grep -o 'Cable([^)]*)')
	role=$(R 'cd /sys/class/typec/port0 2>/dev/null && echo "type=$(cat port_type) power=$(cat power_role) data=$(cat data_role) partner=$([ -d ../port0-partner ] && echo yes || echo no)"')
	devs=$(R 'for d in /sys/bus/usb/devices/*; do [ -f $d/idVendor ] && printf "%s:%s " $(cat $d/idVendor) $(cat $d/idProduct); done')
	echo "cable=${cab:-?} | ${role:-role ?} | usb=[${devs% }]"
}
if [ "$mode" = kernel ]; then
	echo "== uname"; R 'uname -a; cat /proc/version'
	echo "== props"; R 'getprop | grep -E "ro.lineage|ro.build.(fingerprint|version.release|date|id)|ro.product.(device|model)|ro.boot.bootloader|ro.bootimage|ro.build.flavor"'
	echo "== module support"; R 'zcat /proc/config.gz | grep -E "^CONFIG_MODULES|MODULE_SIG|MODVERSIONS|MODULE_FORCE|MODULE_UNLOAD|CONFIG_LOCALVERSION|CONFIG_CC_|STRICT_MEMORY|CONFIG_KALLSYMS=|TIMA|RKP|LKM|CONFIG_MII|USB_NET|USBNET|CDC|_NCM|RNDIS|SR9|CH9|R8152"'
	echo "== loaded modules"; R 'cat /proc/modules | head -40; echo "(count $(wc -l < /proc/modules))"'
	echo "== module dirs"; R 'ls -la /vendor/lib/modules /system/lib/modules /lib/modules /vendor_dlkm/lib/modules 2>&1 | head -30'
	echo "== modprobe/insmod"; R 'which insmod modprobe; ls -la /proc/sys/kernel/modules_disabled 2>&1; cat /proc/sys/kernel/modules_disabled 2>&1'
	echo "== full kernel config"; R 'zcat /proc/config.gz'
	exit 0
fi
devlist() {
	R 'for d in /sys/bus/usb/devices/*; do [ -f $d/idVendor ] || continue; echo "${d##*/} $(cat $d/idVendor):$(cat $d/idProduct) class=$(cat $d/bDeviceClass 2>/dev/null) $(cat $d/manufacturer 2>/dev/null) / $(cat $d/product 2>/dev/null)"; for i in $d/*:*; do [ -d $i ] && echo "   iface ${i##*/} class=$(cat $i/bInterfaceClass) driver=$(basename $(readlink $i/driver 2>/dev/null) 2>/dev/null)"; done; done' |
	while read -r l; do v=$(echo "$l" | grep -o ' [0-9a-f]\{4\}:' | head -1 | tr -d ' :'); echo "$l${v:+  [$(vname $v)]}"; done
	R 'ls /sys/class/net | tr "\n" " "; echo; ip -br addr 2>/dev/null | grep -vE "^(lo|rmnet|ip6tnl|sit|umts|p2p|swlan|dummy)"'
}
if [ "$mode" = force-source ]; then
	[ "$secs" -gt 300 ] && secs=300
	P=/sys/class/typec/port0/port_type
	orig=$(R "cat $P" | grep -o '\[[a-z]*\]' | tr -d '[]'); orig=${orig:-dual}
	restore() { R "echo $orig > $P"; echo "$(date '+%T') restored port_type to $orig -> $(R "cat $P")"; echo "$(date '+%T') after restore: $(state)"; }
	trap 'restore; exit' EXIT INT TERM HUP
	echo "$(date '+%T') before: $(state)   (original port_type=$orig)"
	echo "$(date '+%T') writing source: $(R "echo source > $P && echo ok")  now: $(R "cat $P")"
	prev=""; shown=""; end=$((SECONDS + secs))
	while [ $SECONDS -lt $end ]; do
		cur=$(state); [ "$cur" != "$prev" ] && { echo "$(date '+%T') $cur"; prev=$cur; }
		case "$cur" in *"usb=[]"*) ;; *) [ -z "$shown" ] && { sleep 4; echo "== devices appeared:"; devlist; shown=1; };; esac
		sleep 2
	done
	echo "== end of window: devices / interfaces"; devlist
	echo "== kernel log from the window"
	R "dmesg | grep -vE 'sec-battery|dhd|SSP|audit|CFG80211|BAR0|FG\]|afc_temp|muic_print' | grep -iE 'usb|otg|xhci|dwc|ccic|pdic|muic|typec|vbus|ax88|asix|r815|cdc|ncm|eth[0-9]|hub' | tail -50"
	exit 0
fi
if [ "$mode" = watch ]; then
	echo "watching for $secs s (2 s steps); replug / flip the cable now"
	prev=""; end=$((SECONDS + secs))
	while [ $SECONDS -lt $end ]; do
		cur=$(state); [ "$cur" != "$prev" ] && { echo "$(date '+%T') $cur"; prev=$cur; }; sleep 2
	done
	echo "== kernel log lines from the watch window (USB / Type-C related)"
	R "dmesg | grep -vE 'sec-battery|dhd|SSP|audit|CFG80211|BAR0' | grep -iE 'usb|otg|xhci|dwc|ccic|pdic|muic|typec|cc_|rprd|vbus|ax88|asix|r815|cdc|eth[0-9]' | tail -60"
	exit 0
fi
echo "== state";             state
echo "== USB devices"
R 'for d in /sys/bus/usb/devices/*; do [ -f $d/idVendor ] || continue; echo "${d##*/} $(cat $d/idVendor):$(cat $d/idProduct) class=$(cat $d/bDeviceClass 2>/dev/null) $(cat $d/manufacturer 2>/dev/null) / $(cat $d/product 2>/dev/null) driver=$(basename $(readlink $d/driver 2>/dev/null) 2>/dev/null)"; for i in $d/*:*; do [ -d $i ] && echo "   iface ${i##*/} class=$(cat $i/bInterfaceClass) driver=$(basename $(readlink $i/driver 2>/dev/null) 2>/dev/null)"; done; done' |
	while read -r l; do v=$(echo "$l" | grep -o ' [0-9a-f]\{4\}:' | head -1 | tr -d ' :'); echo "$l${v:+  [$(vname $v)]}"; done
echo "== dumpsys usb (host connections + port)"
R 'dumpsys usb' | tr -s ' ' | grep -E 'device_address|manufacturer=|product=|timestamp|id=|supported_modes|connected=|current_mode|power_role|data_role|host_connected|kernel_state|kernel_function|sink_power|source_power|num_connects'
echo "== Type-C / CCIC sysfs"
R 'for f in /sys/class/typec/*/* /sys/class/sec/ccic/* /sys/class/sec/switch/* /sys/class/power_supply/otg/* /sys/class/power_supply/usb/online /sys/class/power_supply/usb/type /sys/class/power_supply/battery/online; do [ -f "$f" ] && [ -r "$f" ] && printf "%s = %s\n" "$f" "$(head -c 200 "$f" 2>/dev/null | tr "\n" " ")"; done' | grep -v 'uevent\|Permission' | head -80
echo "== props"; R 'getprop | grep -iE "usb|otg"' | head -20
echo "== network"; R 'ls /sys/class/net; ip -br addr 2>/dev/null; echo "-- neighbours"; ip neigh 2>/dev/null; echo "-- rndis/ncm/usb iface stats"; for i in /sys/class/net/rndis* /sys/class/net/usb* /sys/class/net/ncm*; do [ -d $i ] && echo "${i##*/} oper=$(cat $i/operstate) rx=$(cat $i/statistics/rx_packets) tx=$(cat $i/statistics/tx_packets)"; done'
echo "== tethering"; R 'dumpsys tethering 2>/dev/null | grep -iE "state|iface|usb|rndis|ncm|downstream|upstream|dhcp|lease|error" | head -40'
echo "== gadget log"; R "dmesg | grep -iE 'rndis|ncm|gadget|android_work|configfs|set_config|usb_ep|ipa|tether' | tail -25"
 R 'pm list features | grep -i ethernet' || echo "(no android.hardware.ethernet feature)"
echo "== kernel log (USB / Type-C related, last 60)"
R "dmesg | grep -vE 'sec-battery|dhd|SSP|audit|CFG80211|BAR0' | grep -iE 'usb|otg|xhci|dwc|ccic|pdic|muic|typec|cc_|rprd|vbus|ax88|asix|r815|cdc|eth[0-9]' | tail -60"
