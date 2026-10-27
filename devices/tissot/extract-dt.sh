#!/bin/bash
# ============================================================================
# devices/tissot/extract-dt.sh
#
# Fetch the Xiaomi Mi A1 (tissot) STOCK device tree from its firmware, for
# reference / hardware init BEFORE XNU. The booted iOS image uses a *faked*
# iPhone X (d22ap) DT (see build-bootimage.sh); the real tissot DT is needed
# to understand the actual MSM8953 peripherals while writing drivers.
#
# NOTE: this is a TEMPLATE. Provide a real Mi A1 fastboot-firmware URL.
# Xiaomi firmware is a .tgz containing images/ (boot.img, dtbo.img, ...).
# The DTB lives in boot.img / dtbo.img (DTB overlay).
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/dt"
mkdir -p "$OUT"

FIRMWARE_URL="${1:-}"
if [ -z "$FIRMWARE_URL" ]; then
    echo "Usage: $0 <mi_a1_fastboot_firmware_url>"
    echo ""
    echo "Get a tissot fastboot firmware from:"
    echo "  https://xiaomifirmwareupdater.com/  (search 'tissot')"
    echo ""
    echo "Then, to extract the DTB from the firmware:"
    echo "  tar xzf tissot_*.tgz                       # -> images/"
    echo "  # boot.img"
    echo "  mkbootimg --unpack images/boot.img          # -> kernel, dtb, ramdisk"
    echo "  # dtbo.img (overlay)"
    echo "  fdtoverlay -i images/dtbo.img -o tissot.dtbo.dtb"
    echo "  dtc -I dtb -O dts tissot.dtbo.dtb > tissot-stock.dts"
    exit 1
fi

echo ">>> Downloading firmware (this is large - run on your own machine)..."
if command -v curl &>/dev/null; then
    curl -L -o "$OUT/tissot-fw.tgz" "$FIRMWARE_URL"
else
    wget -O "$OUT/tissot-fw.tgz" "$FIRMWARE_URL"
fi

echo ">>> Unpack + extract DTB (manual steps above apply):"
tar xzf "$OUT/tissot-fw.tgz" -C "$OUT" || true
echo ">>> Done. Inspect $OUT/images/boot.img and dtbo.img for the DTB."
