#!/bin/bash
# ============================================================================
# xnu/apply-8020.sh — Fetch Apple's XNU 8020 (iOS 15) source and apply the
#                     HakiOS/tissot patch series.
#
# iOS 15 kernel = xnu-8020 series. Apple publishes only three 8020 tags:
#   xnu-8020.101.4   (iOS 15.0)
#   xnu-8020.121.3
#   xnu-8020.140.41  <- latest published; what we use
#
# Output: xnu-src-8020/  (patched, ready to build)
#
# Usage:
#   ./xnu/apply-8020.sh                 # fetch (if needed) + apply patches
#   ./xnu/apply-8020.sh --refetch       # delete and re-download
#   XNU_TAG=xnu-8020.121.3 ./xnu/apply-8020.sh
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG="${XNU_TAG:-xnu-8020.140.41}"
SRC="$ROOT/xnu-src-8020"
PATCHES="$SCRIPT_DIR/patches-8020"
URL="https://github.com/apple-oss-distributions/xnu/archive/refs/tags/${TAG}.tar.gz"
TARBALL="$ROOT/xnu-deps/build/${TAG}.tar.gz"

echo ""
echo "============================================================"
echo "  XNU 8020 (iOS 15) source + HakiOS/tissot patches"
echo "============================================================"
echo "  tag    : $TAG"
echo "  source : $SRC"
echo "  patches: $PATCHES"
echo ""

# ---- refetch ----
if [ "$1" = "--refetch" ]; then
    echo ">>> removing $SRC"
    rm -rf "$SRC"
fi

# ---- fetch ----
if [ ! -d "$SRC" ] || [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
    mkdir -p "$(dirname "$TARBALL")"
    if [ ! -f "$TARBALL" ]; then
        echo ">>> downloading $URL"
        if command -v curl >/dev/null 2>&1; then
            curl -L --fail -o "$TARBALL" "$URL"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$TARBALL" "$URL"
        else
            echo "ERROR: need curl or wget to download the source."
            exit 1
        fi
    else
        echo ">>> using cached $TARBALL"
    fi

    echo ">>> extracting (stripping top-level dir)..."
    mkdir -p "$SRC"
    tar xzf "$TARBALL" -C "$SRC" --strip-components=1
    echo "    $(find "$SRC" -type f | wc -l) files"
else
    echo ">>> source already present, skipping download"
fi

# ---- apply patches ----
echo ""
echo ">>> applying patches"
shopt -s nullglob
patches=("$PATCHES"/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
    echo "    (no patches found in $PATCHES)"
else
    for p in "${patches[@]}"; do
        name="$(basename "$p")"
        echo "    - $name"
        # Already applied? A successful *reverse* dry-run proves it.
        # (Do not add --forward here: it conflicts with -R.)
        if patch -p1 -d "$SRC" --dry-run -R -i "$p" >/dev/null 2>&1; then
            echo "      already applied (skipped)"
        elif patch -p1 -d "$SRC" --forward --silent -i "$p"; then
            echo "      applied"
        else
            echo "      FAILED to apply"
            echo "      Inspect: patch -p1 -d $SRC --dry-run -i $p"
            exit 1
        fi
    done
fi

# ---- sanity check ----
echo ""
echo ">>> sanity check"
if [ -f "$SRC/pexpert/pexpert/arm64/TISSOT.h" ]; then
    echo "    TISSOT.h present"
else
    echo "    ERROR: TISSOT.h missing — patch did not apply"
    exit 1
fi
if grep -q "MACHINE_FLAGS_ARM64_TISSOT" "$SRC/makedefs/MakeInc.def"; then
    echo "    MACHINE_FLAGS_ARM64_TISSOT registered"
else
    echo "    ERROR: tissot machine config missing"
    exit 1
fi

echo ""
echo ">>> Done. Next:"
echo "      ./xnu-build-arm64.sh --check     # verify toolchain"
echo "      ./xnu-build-arm64.sh             # build (needs macOS + cctools)"
echo ""
