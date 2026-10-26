#!/bin/bash
# ============================================================================
# xnu-build-x86.sh — Build the XNU kernel for x86_64 (HakiOS platform)
#
# Usage: ./xnu-build-x86.sh [-j8] [-c DEVELOPMENT|RELEASE|DEBUG]
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
XNU_SRC="$SCRIPT_DIR/xnu-src"

# Defaults
JOBS=8
KERNEL_CONFIG="DEVELOPMENT"
SDKROOT="${SDKROOT:-macosx.internal}"

# Parse args
while getopts "j:c:k" opt; do
    case $opt in
        j) JOBS="$OPTARG" ;;
        c) KERNEL_CONFIG="$OPTARG" ;;
        k) KEEP=1 ;;
        *) ;;
    esac
done

echo ">>> HakiOS-x86: building XNU kernel"
echo ">>> Config:     $KERNEL_CONFIG"
echo ">>> Arch:       X86_64"
echo ">>> Jobs:       $JOBS"
echo ">>> SDK:        $SDKROOT"
echo ""

# Check that XNU source exists
if [ ! -d "$XNU_SRC" ]; then
    echo ">>> XNU source not found. Running apply.sh first..."
    "$SCRIPT_DIR/xnu/apply.sh"
fi

cd "$XNU_SRC"

# ---- Set up build environment ----
# On Linux, we need the cross-compile toolchain
CCTOOLS_DIR="$ROOT_DIR/xnu-deps/cctools"
if [ -d "$CCTOOLS_DIR" ]; then
    export PATH="$CCTOOLS_DIR/usr/local/bin:$PATH"
fi

# Determine SDK path for headers
SDK_PATH="${SDK_PATH:-}"
if [ -z "$SDK_PATH" ]; then
    # Try to find the SDK in xnu-deps
    for sdk in "$ROOT_DIR"/xnu-deps/*.sdk "$ROOT_DIR"/xnu-deps/MacOSX*.sdk; do
        if [ -d "$sdk" ]; then
            SDK_PATH="$sdk"
            break
        fi
    done
fi

if [ -n "$SDK_PATH" ] && [ -d "$SDK_PATH" ]; then
    export SDKROOT="$SDK_PATH"
    echo ">>> Using SDK: $SDKROOT"
else
    echo ">>> WARNING: no SDK found. Build may fail."
    echo ">>> Set SDK_PATH or SDKROOT to your macOS SDK location."
fi

# ---- Build XNU ----
echo ""
echo ">>> Starting XNU build (ARCH_CONFIGS=X86_64)..."

# XNU's build system uses make with ARCH_CONFIGS
# The TARGET_CONFIGS for our platform is 'hakios'
make -j"$JOBS" \
    ARCH_CONFIGS=X86_64 \
    KERNEL_CONFIGS="$KERNEL_CONFIG" \
    TARGET_CONFIGS=hakios \
    SDKROOT="$SDKROOT" \
    2>&1 | tee "$ROOT_DIR/logs/xnu-build.log" || {

    # If the full build fails, try a minimal build
    echo ""
    echo ">>> Full build failed. Attempting minimal build..."
    make -j"$JOBS" \
        ARCH_CONFIGS=X86_64 \
        KERNEL_CONFIGS="$KERNEL_CONFIG" \
        SDKROOT="$SDKROOT" \
        exporthdrs 2>&1 | tee -a "$ROOT_DIR/logs/xnu-build.log"

    make -j"$JOBS" \
        ARCH_CONFIGS=X86_64 \
        KERNEL_CONFIGS="$KERNEL_CONFIG" \
        SDKROOT="$SDKROOT" \
        all 2>&1 | tee -a "$ROOT_DIR/logs/xnu-build.log"
}

# ---- Find the built kernel ----
echo ""
echo ">>> Looking for built kernel..."
KERNEL_FILE=$(find "$XNU_SRC" -name "mach.$KERNEL_CONFIG*" -type f 2>/dev/null | head -1)

if [ -n "$KERNEL_FILE" ]; then
    echo ">>> Found kernel: $KERNEL_FILE"
    mkdir -p "$ROOT_DIR/prebuilt"
    cp "$KERNEL_FILE" "$ROOT_DIR/prebuilt/mach.$KERNEL_CONFIG.x86_64"
    echo ">>> Copied to: $ROOT_DIR/prebuilt/mach.$KERNEL_CONFIG.x86_64"
    echo ""
    echo ">>> Kernel build successful!"
else
    echo ">>> WARNING: kernel file not found in build output."
    echo ">>> Check logs/xnu-build.log for details."
    echo ">>> Common xnu-src build locations:"
    find "$XNU_SRC" -name "mach.*" -type f 2>/dev/null || true
fi
