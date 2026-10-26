#!/bin/bash
# ============================================================================
# xnu/apply.sh — Clone Apple's XNU source and apply the HakiOS-x86 patch
#
# This downloads xnu-8796.121.2 from Apple's GitHub, then layers our
# changes on top. The result is in xnu-src/.
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
XNU_SRC="$ROOT_DIR/xnu-src"
PATCH="$SCRIPT_DIR/hakios-x86.patch"
FILES_DIR="$SCRIPT_DIR/files"

XNU_VERSION="8796.121.2"
XNU_REPO="https://github.com/apple/darwin-xnu.git"
XNU_BRANCH="xnu-$XNU_VERSION"

echo ">>> HakiOS-x86: applying XNU patch"
echo ">>> XNU version: $XNU_VERSION"
echo ">>> Target: x86_64"
echo ""

# ---- Step 1: Clone XNU source (if not already done) ----
if [ ! -d "$XNU_SRC" ]; then
    echo ">>> Cloning XNU from Apple's GitHub (this is ~200MB)..."
    git clone --depth 1 --branch "$XNU_BRANCH" "$XNU_REPO" "$XNU_SRC" || {
        echo ">>> Clone failed. Trying default branch..."
        git clone --depth 1 "$XNU_REPO" "$XNU_SRC"
    }
    echo ">>> XNU cloned to $XNU_SRC"
else
    echo ">>> XNU source already present at $XNU_SRC"
fi

# ---- Step 2: Apply the HakiOS-x86 patch ----
echo ">>> Applying HakiOS-x86 patch..."
cd "$XNU_SRC"

# Reset to clean state (in case we're re-running)
git checkout -- . 2>/dev/null || true
git clean -fd 2>/dev/null || true

# Apply our patch
if [ -f "$PATCH" ]; then
    git apply "$PATCH" || {
        echo ">>> Patch application failed. Trying with --3way..."
        git apply --3way "$PATCH" || {
            echo ">>> ERROR: Could not apply patch. Check $PATCH"
            exit 1
        }
    }
    echo ">>> Patch applied."
else
    echo ">>> WARNING: patch file $PATCH not found. Using files/ directory only."
fi

# ---- Step 3: Copy our driver files ----
echo ">>> Copying HakiOS-x86 driver files..."
if [ -d "$FILES_DIR" ]; then
    cp -rv "$FILES_DIR"/* "$XNU_SRC/" 2>/dev/null || {
        echo ">>> Copy completed (some files may not have matched)."
    }
    echo ">>> Driver files copied."
fi

# ---- Step 4: Create the HakiOS target config ----
echo ">>> Creating HakiOS x86_64 target config..."
CONFIG_DIR="$XNU_SRC/config"
if [ -d "$CONFIG_DIR" ]; then
    # Create our target configuration file
    cat > "$CONFIG_DIR/hakios.x86_64" << 'TARGET_EOF'
#
# HakiOS x86_64 target configuration
# This file tells XNU how to build for the HakiOS-x86 platform.
#

# Platform: use our custom platform expert
PLATFORM_NAME := hakios

# Architecture: x86_64
ARCH_CONFIG := X86_64

# Kernel configs available for this target
KERNEL_CONFIGS := DEVELOPMENT RELEASE DEBUG

# Additional source files (our drivers)
HAKIOS_DRIVERS = $(addprefix bsd/dev/, \
    hakios.display.c \
    hakios.input.c \
    hakios.disk.c \
    hakios.net.c \
    hakios.audio.c \
    hakios.timer.c \
    hakios.serial.c \
    hakios.pci.c \
)

# Add our drivers to the build
CFLAGS_HAKIOS := -DHAKIOS_X86 -DHAKIOS_PLATFORM -DHAKIOS_Q35
export CFLAGS_HAKIOS

TARGET_EOF
    echo ">>> Target config created at $CONFIG_DIR/hakios.x86_64"
fi

echo ""
echo ">>> Done. XNU source is ready at: $XNU_SRC"
echo ">>> Build with: ./xnu-build-x86.sh"
