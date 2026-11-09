#!/bin/bash
# Pull the Mi A1's own flattened device tree from the running phone, over adb. Read only: nothing is written to the phone.
#
# usage: devices/tissot/pull-fdt.sh [output.dtb]        (default: devices/tissot/dt/phone.dtb)
#
# The phone must be on, with USB debugging allowed for this computer ("adb devices" shows it as "device", not "unauthorized").
# Android's kernel shows the device tree it was started with as /sys/firmware/fdt; the shell user may not be allowed to read
# it, in which case this tries root (su) if the phone has it. Whatever it pulls is checked: a device tree starts with the
# bytes d0 0d fe ed.
set -e
cd "$(dirname "$0")"
OUT=${1:-dt/phone.dtb}
mkdir -p "$(dirname "$OUT")"

command -v adb >/dev/null || { echo "pull-fdt: adb is not installed (Android platform-tools)"; exit 1; }
state=$(adb get-state 2>&1 || true)
[ "$state" = device ] || { echo "pull-fdt: no phone ready over adb (adb get-state says: $state). Plug it in, allow USB debugging."; exit 1; }
echo "phone: $(adb shell getprop ro.product.device | tr -d '\r') / $(adb shell getprop ro.product.model | tr -d '\r') / $(adb shell getprop ro.board.platform | tr -d '\r')"

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
magic() { head -c 4 "$1" | od -An -tx1 | tr -d ' \n'; }

adb exec-out 'cat /sys/firmware/fdt' > "$tmp" 2>/dev/null || true
if [ "$(magic "$tmp")" != d00dfeed ]; then
	echo "pull-fdt: the shell user cannot read /sys/firmware/fdt, trying su"
	adb exec-out 'su -c "cat /sys/firmware/fdt"' > "$tmp" 2>/dev/null || true
fi
if [ "$(magic "$tmp")" != d00dfeed ]; then
	echo "pull-fdt: could not read the device tree (no read access, and no root). Options: a rooted phone, or TWRP: boot it and run"
	echo "          adb pull /sys/firmware/fdt"
	exit 1
fi
cp "$tmp" "$OUT"
echo "pulled $(wc -c < "$OUT") bytes to $OUT (sha256 $(sha256sum "$OUT" | cut -c1-16)...)"
command -v dtc >/dev/null && dtc -I dtb -O dts "$OUT" 2>/dev/null | grep -E 'model =|qcom,msm-id|qcom,board-id|compatible = "qcom' | head -4
echo "next: compare with devices/tissot/reference/tissot-from-linux-dts.dtb (made from the Linux DTS, not from a phone):"
echo "      dtc -I dtb -O dts $OUT > phone.dts; dtc -I dtb -O dts reference/tissot-from-linux-dts.dtb > ref.dts; diff ref.dts phone.dts | less"
