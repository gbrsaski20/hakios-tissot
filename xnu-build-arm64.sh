#!/bin/bash
# ============================================================================
# xnu-build-arm64.sh — Build XNU 8020 for the Xiaomi Mi A1 (tissot / MSM8953)
#
# Target: ARM64, machine config TISSOT (added by xnu/patches-8020/0001).
#
# IMPORTANT — what this needs:
#   XNU does not build with a bare Linux toolchain. It needs Apple's build
#   environment: clang + cctools (ld, ctf_insert, kextsymboltool) + a macOS
#   or iPhoneOS SDK. In practice this means macOS, or the GitHub Actions
#   macOS runner used by ios-sweet (see docs/XNU8020-PORT-PLAN.md).
#
#   This script therefore:
#     --check   verifies the toolchain and tells you exactly what is missing
#     --print   prints the make command without running it
#     (default) runs the build
#
# Usage:
#   ./xnu-build-arm64.sh --check
#   ./xnu-build-arm64.sh --print
#   ./xnu-build-arm64.sh                    # SDKROOT defaults to "iphoneos"
#   SDKROOT=iphoneos ./xnu-build-arm64.sh
#   ./xnu-build-arm64.sh --config RELEASE --jobs 8
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR"
SRC="$ROOT/xnu-src-8020"
MACHINE="TISSOT"
CONFIG="DEVELOPMENT"
JOBS=""
MODE="build"
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check)  MODE="check" ;;
        --print)  MODE="print" ;;
        --force)  FORCE=1 ;;
        --config) CONFIG="$2"; shift ;;
        --jobs)   JOBS="$2"; shift ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
    shift
done

[ -z "$JOBS" ] && JOBS="$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) )"

echo ""
echo "============================================================"
echo "  XNU 8020 -> tissot (ARM64, machine config $MACHINE)"
echo "============================================================"
echo "  source : $SRC"
echo "  config : $CONFIG"
echo "  jobs   : $JOBS"
echo ""

# ---------------------------------------------------------------------------
# 0. source present?
# ---------------------------------------------------------------------------
if [ ! -f "$SRC/makedefs/MakeInc.def" ]; then
    echo "ERROR: XNU source not found at $SRC"
    echo "       Run: ./xnu/apply-8020.sh"
    exit 1
fi
if ! grep -q "MACHINE_FLAGS_ARM64_TISSOT" "$SRC/makedefs/MakeInc.def"; then
    echo "ERROR: tissot board config not applied."
    echo "       Run: ./xnu/apply-8020.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. toolchain checks
# ---------------------------------------------------------------------------
missing=0
note() { echo "    $1"; }

echo ">>> toolchain"
if command -v clang >/dev/null 2>&1; then
    note "clang  : $(clang --version | head -1)"
else
    note "clang  : MISSING"
    missing=1
fi

for tool in ld ctf_insert kextsymboltool; do
    if command -v "$tool" >/dev/null 2>&1; then
        note "$tool : ok"
    else
        note "$tool : MISSING (part of Apple cctools)"
        missing=1
    fi
done

if command -v make >/dev/null 2>&1; then
    note "make   : ok"
else
    note "make   : MISSING"
    missing=1
fi

if command -v xcrun >/dev/null 2>&1; then
    sdk_name="${SDKROOT:-iphoneos}"
    sdk_path="$(xcrun -sdk "$sdk_name" -show-sdk-path 2>/dev/null || true)"
    if [ -n "$sdk_path" ]; then
        note "SDKROOT: $sdk_name -> $sdk_path"
    else
        note "SDKROOT: '$sdk_name' not resolvable (need the iOS SDK)"
        missing=1
    fi
else
    note "xcrun  : MISSING (needed to resolve SDKROOT)"
    missing=1
fi

# host must be macOS for a real build
if [ "$(uname -s)" != "Darwin" ]; then
    note "host   : $(uname -s) — XNU builds on macOS only"
    missing=1
fi

echo ""

# ---------------------------------------------------------------------------
# 2. build command
#
# PLATFORM is derived by makedefs/MakeInc.cmd from
#   xcrun -sdk $(SDKROOT) -show-sdk-platform-path
# so passing SDKROOT=iphoneos yields PLATFORM=iPhoneOS automatically.
# Do NOT pass PLATFORM explicitly (it must be undefined for that derivation).
# ---------------------------------------------------------------------------
SDK_NAME="${SDKROOT:-iphoneos}"

MAKE_CMD=(make -C "$SRC" -j"$JOBS"
          ARCH_CONFIGS=ARM64
          KERNEL_CONFIGS="$CONFIG"
          CURRENT_MACHINE_CONFIG="$MACHINE"
          SDKROOT="$SDK_NAME")

case "$MODE" in
    check)
        if [ "$missing" -eq 0 ]; then
            echo ">>> toolchain OK — ready to build"
            echo "    ./xnu-build-arm64.sh"
            exit 0
        else
            echo ">>> toolchain INCOMPLETE (see MISSING above)"
            echo ""
            echo "    XNU cannot be built here. Options:"
            echo "      a) build on a Mac with Xcode + cctools"
            echo "      b) use the GitHub Actions macOS runner (recommended),"
            echo "         see docs/XNU8020-PORT-PLAN.md"
            exit 1
        fi
        ;;
    print)
        echo ">>> command:"
        echo "    ${MAKE_CMD[*]}"
        exit 0
        ;;
esac

if [ "$missing" -ne 0 ] && [ "$FORCE" -ne 1 ]; then
    echo ">>> refusing to build: toolchain incomplete."
    echo "    Run ./xnu-build-arm64.sh --check for details."
    echo "    Use --force to attempt the build anyway (useful in CI to get"
    echo "    the real compiler error instead of stopping at the precheck)."
    exit 1
fi

if [ "$missing" -ne 0 ]; then
    echo ">>> WARNING: incomplete toolchain, continuing because of --force."
    echo "    Expect failures below; the first real error is the useful part."
    echo ""
fi

# ---------------------------------------------------------------------------
# 3. build
# ---------------------------------------------------------------------------
echo ">>> building..."
"${MAKE_CMD[@]}"
rc=$?
echo ""

if [ $rc -ne 0 ]; then
    echo ">>> BUILD FAILED (exit $rc)"
    echo "    Common causes for a non-Apple target:"
    echo "      - pexpert/arm64/board_config.h needs more TISSOT knobs"
    echo "      - ARM64_LINK_ADDR must match where the bootloader loads the kernel"
    echo "      - missing Apple-only headers/kexts for embedded targets"
    exit $rc
fi

# ---------------------------------------------------------------------------
# 4. locate output
# ---------------------------------------------------------------------------
echo ">>> locating kernel output"
found="$(find "$SRC/BUILD/obj" -maxdepth 2 -type f -name "kernel.*" 2>/dev/null | head -5)"
if [ -n "$found" ]; then
    echo "$found" | while read -r f; do
        echo "    $f  ($(wc -c < "$f") bytes)"
    done
    mkdir -p "$ROOT/prebuilt"
    first="$(echo "$found" | head -1)"
    cp "$first" "$ROOT/prebuilt/tissot-kernel-arm64.Image"
    echo ""
    echo ">>> copied to prebuilt/tissot-kernel-arm64.Image"
    echo ">>> now repack the boot image:"
    echo "      ./devices/tissot/build-bootimage.sh --kernel prebuilt/tissot-kernel-arm64.Image"
else
    echo "    no kernel.* found under $SRC/BUILD/obj"
    echo "    check the build log"
fi
echo ""
