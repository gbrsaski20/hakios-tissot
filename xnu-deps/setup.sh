#!/bin/bash
# ============================================================================
# xnu-deps/setup.sh — Install build dependencies for XNU x86_64 on Linux
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo ">>> HakiOS-x86 dependency setup"
echo ">>> Target: XNU x86_64 build on Linux"
echo ""

# ---- Check for required tools ----
check_tool() {
    if command -v "$1" &>/dev/null; then
        echo "  [OK] $1 found"
    else
        echo "  [MISSING] $1 — please install: $2"
        MISSING=1
    fi
}

MISSING=0

echo ">>> Checking build tools..."
check_tool clang       "apt install clang  (need version 14+)"
check_tool lld         "apt install lld"
check_tool ld          "apt install binutils"
check_tool make        "apt install build-essential"
check_tool git         "apt install git"
check_tool python3    "apt install python3"
check_tool 7z          "apt install p7zip-full  (need 7-Zip 23+)"
check_tool lz4         "apt install liblz4-tool"
check_tool qemu-system-x86_64 "apt install qemu-system-x86"

# ---- Install macOS cross-compilation toolchain (cctools) ----
# XNU can be built on Linux with cctools-port
if [ ! -d "$SCRIPT_DIR/cctools" ]; then
    echo ""
    echo ">>> Installing cctools-port (for cross-compiling XNU on Linux)..."
    git clone https://github.com/sbingner/cctools-port.git "$SCRIPT_DIR/cctools" || {
        echo ">>> WARNING: cctools clone failed. You may need to install manually."
        echo ">>> See: https://github.com/sbingner/cctools-port"
    }
    
    # Build cctools for x86_64-apple-darwin
    if [ -d "$SCRIPT_DIR/cctools" ]; then
        echo ">>> Building cctools..."
        cd "$SCRIPT_DIR/cctools"
        ./autogen.sh 2>/dev/null || true
        ./configure --target=x86_64-apple-darwin14 || {
            echo ">>> cctools configure failed, but continuing."
        }
        make -j$(nproc) || {
            echo ">>> cctools build failed, but continuing."
        }
        cd "$ROOT_DIR"
    fi
else
    echo "  [OK] cctools already present"
fi

# ---- Fetch macOS SDK for headers ----
# XNU needs macOS SDK headers to build on Linux
SDK_DIR="$SCRIPT_DIR/MacOSX11.3.sdk"
if [ ! -d "$SDK_DIR" ]; then
    echo ""
    echo ">>> macOS SDK headers are needed for XNU build."
    echo ">>> Option 1: On a Mac, run 'xcrun --show-sdk-path' and copy the SDK."
    echo ">>> Option 2: Use the theos SDK (https://github.com/theos/sdks)."
    echo ">>> Option 3: The SDK is fetched automatically by xnu/apply.sh."
    echo ""
    echo ">>> For the open build (no iOS user space), the bare SDK is sufficient."
fi

echo ""
if [ "$MISSING" = "1" ]; then
    echo ">>> Some tools are missing. Install them and re-run."
    exit 1
fi

echo ">>> All dependencies present."
echo ">>> Next: run 'make x86-open' to build the open kernel."
