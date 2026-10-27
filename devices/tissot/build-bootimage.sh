#!/bin/bash
# ============================================================================
# devices/tissot/build-bootimage.sh
#
# Build a flashable Android boot image for Xiaomi Mi A1 (tissot / MSM8953).
#
# This is the REAL implementation (the old version was a mkbootimg template).
# It uses the pure-Python toolchain in tools/, so it needs no mkbootimg,
# no dtc, and no compiler:
#
#   tools/build_kernel_placeholder_arm64.py  -> prebuilt/tissot-kernel-arm64.Image
#   tools/build_tissot_dtb.py                -> prebuilt/tissot.dtb
#   tools/make_tissot_bootimg.py             -> prebuilt/tissot-boot.img
#
# Usage:
#   ./build-bootimage.sh                       # build everything
#   ./build-bootimage.sh --kernel my-kernel    # use your own XNU ARM64 Image
#   ./build-bootimage.sh --dtb my.dtb          # use your own device tree
#   ./build-bootimage.sh --ramdisk ios-root.simg --out tissot-ios-boot.img
#
# Note on the ios-sweet approach: ios-sweet feeds XNU a FAKED iPhone X
# (d22ap) device tree. If you have that DT, pass it with --dtb. The default
# DT generated here describes the REAL MSM8953 silicon (useful for driver
# development and for understanding the hardware).
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLS="$ROOT/tools"
PREBUILT="$ROOT/prebuilt"

# ---- pick a python interpreter ----
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
    for cand in python3 python py; do
        if command -v "$cand" >/dev/null 2>&1; then
            PY="$cand"
            break
        fi
    done
fi
if [ -z "$PY" ]; then
    echo "ERROR: no python interpreter found (tried python3, python, py)."
    echo "       Install Python 3, or set PYTHON=/path/to/python"
    exit 1
fi

echo ""
echo "============================================================"
echo "  Mi A1 (tissot / MSM8953) boot image builder"
echo "============================================================"
echo "  python : $PY"
echo "  root   : $ROOT"
echo ""

mkdir -p "$PREBUILT"

# ---- rebuild if missing OR if the generator script is newer than the output ----
needs_build() {
    local out="$1" src="$2"
    [ ! -f "$out" ] && return 0
    [ "$src" -nt "$out" ] && return 0
    return 1
}

# ---- 1. ARM64 kernel ----
if needs_build "$PREBUILT/tissot-kernel-arm64.Image" \
               "$TOOLS/build_kernel_placeholder_arm64.py"; then
    echo ">>> [1/3] Building ARM64 placeholder kernel..."
    "$PY" "$TOOLS/build_kernel_placeholder_arm64.py"
    echo ""
else
    echo ">>> [1/3] ARM64 kernel up to date, skipping."
    echo ""
fi

# ---- 2. device tree ----
if needs_build "$PREBUILT/tissot.dtb" "$TOOLS/build_tissot_dtb.py"; then
    echo ">>> [2/3] Building device tree (tissot.dtb)..."
    "$PY" "$TOOLS/build_tissot_dtb.py"
    echo ""
else
    echo ">>> [2/3] Device tree up to date, skipping."
    echo ""
fi

# ---- 3. pack the boot image (all extra args are passed through) ----
echo ">>> [3/3] Packing Android boot image..."
"$PY" "$TOOLS/make_tissot_bootimg.py" "$@"

echo ""
echo ">>> Done."
echo ">>> Flash:  fastboot boot  prebuilt/tissot-boot.img"
echo ">>> Or:     fastboot flash boot prebuilt/tissot-boot.img"
echo ""
