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

# Stamp file: records a hash of the whole patch set that has been applied to
# $SRC. Needed because "is this patch already applied?" cannot be answered
# reliably by a reverse dry-run once a LATER patch has rewritten the same
# lines: 0002 and 0003 both edit the header comment of TISSOT.h, so reversing
# 0002 on a fully patched tree fails and the script would conclude "not
# applied" and try to apply it forward. The stamp makes re-runs deterministic.
STAMP="$SRC/.haki-patchset"

patch_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        cat "$PATCHES"/*.patch | sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        cat "$PATCHES"/*.patch | shasum -a 256 | cut -d' ' -f1
    else
        cat "$PATCHES"/*.patch | cksum | tr -d ' '
    fi
}

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
    WANT_HASH="$(patch_hash)"
    if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$WANT_HASH" ]; then
        echo "    sudah diterapkan sebelumnya (stamp cocok: ${WANT_HASH})"
        echo "    patch set tidak berubah sejak terakhir apply, melewati langkah ini"
    else
        if [ -f "$STAMP" ]; then
            echo "    CATATAN: stamp ada tapi hash berbeda — patch set berubah."
            echo "             Kalau source ini sudah dipatch, jalankan --refetch."
        fi
        for p in "${patches[@]}"; do
            name="$(basename "$p")"
            echo "    - $name"

            # Order matters. A FORWARD dry-run is the only reliable "needs
            # applying" test: testing reverse first gives false positives for
            # patches that create new files, because reversing a creation is a
            # deletion and `patch` treats that as trivially successful.
            #
            # `</dev/null` + --batch keep patch from ever prompting
            # ("File to patch:"), which in CI silently skips the patch.
            if patch -p1 -d "$SRC" --forward --batch --dry-run -i "$p" </dev/null >/dev/null 2>&1; then
                if patch -p1 -d "$SRC" --forward --batch --silent -i "$p" </dev/null; then
                    echo "      applied"
                else
                    echo "      FAILED: dry-run passed but real apply failed"
                    exit 1
                fi
            elif patch -p1 -d "$SRC" --batch --dry-run -R -i "$p" </dev/null >/dev/null 2>&1; then
                echo "      already applied (skipped)"
            else
                echo "      FAILED to apply"
                echo "      Kalau tree ini sudah dipatch penuh, kegagalan ini normal:"
                echo "      patch yang lebih baru (mis. 0003) menulis ulang baris yang"
                echo "      sama, sehingga reverse dry-run patch lama ikut gagal."
                echo "      Solusi: ./xnu/apply-8020.sh --refetch"
                echo "      Periksa manual: patch -p1 -d $SRC --dry-run -i $p"
                exit 1
            fi
        done
        printf '%s\n' "$WANT_HASH" > "$STAMP"
        echo "    stamp ditulis: $STAMP"
    fi
fi

# ---- sanity check: every patch must leave its markers behind ----
echo ""
echo ">>> sanity check"
fail=0
need_file() {
    if [ -f "$SRC/$1" ]; then echo "    ok   $1"
    else echo "    MISSING FILE  $1"; fail=1; fi
}
need_grep() {
    if grep -q "$2" "$SRC/$1" 2>/dev/null; then echo "    ok   $1 :: $2"
    else echo "    MISSING MARK  $1 :: $2"; fail=1; fi
}
need_absent() {
    if grep -q "$2" "$SRC/$1" 2>/dev/null; then echo "    STILL PRESENT  $1 :: $2"; fail=1
    else echo "    ok   $1 :: tanpa $2"; fi
}

# patch 0001
need_file "pexpert/pexpert/arm64/TISSOT.h"
need_grep "makedefs/MakeInc.def" "MACHINE_FLAGS_ARM64_TISSOT"
need_grep "pexpert/pexpert/arm64/board_config.h" "ARM64_BOARD_CONFIG_TISSOT"
# patch 0002
need_grep "pexpert/pexpert/arm/protos.h" "SERIAL_TISSOT_UART"
need_grep "pexpert/arm/pe_serial.c" "tissot_uart_init"
# patch 0003 (GICv2)
need_grep "pexpert/pexpert/arm64/TISSOT.h" "TISSOT_GIC_V2"
need_grep "pexpert/arm/pe_fiq.c" "tissot_gic_init_distributor"
need_grep "pexpert/arm/pe_fiq.c" "pe_gic_ack_irq"
need_grep "osfmk/arm64/sleh.c" "pe_gic_ack_irq"
# patch 0004 (availability.pl dari SDK host)
need_grep "bsd/sys/make_symbol_aliasing.sh" "HAKIOS_HOST_SDK"
need_grep "bsd/sys/make_symbol_aliasing.sh" "HAKIOS_STATIC_LIST"
# patch 0005 (kompatibilitas clang baru)
need_grep "makedefs/MakeInc.def" "Wno-missing-include-dirs"
need_grep "makedefs/MakeInc.def" "Not every SDK ships usr/local/include/kernel"
need_absent "makedefs/MakeInc.def" "enable-trivial-auto-var-init-zero"
# patch 0006 (warning clang baru)
need_grep "makedefs/MakeInc.def" "Wno-reserved-identifier"
# patch 0007 (ekspor TISSOT.h ke EXPORT_HDRS)
need_grep "pexpert/pexpert/arm64/Makefile" "TISSOT.h"
# patch 0008 (CPU type Cortex-A53 di proc_reg.h)
need_grep "osfmk/arm/proc_reg.h" "ARM64_BOARD_CONFIG_TISSOT"
need_grep "iokit/Kernel/IOStartIOKit.cpp" "!defined(ARM64_BOARD_CONFIG_TISSOT)"

if [ "$fail" -ne 0 ]; then
    echo ""
    echo ">>> ERROR: patch results incomplete (see MISSING above)"
    echo "    A patch may have partially applied. Inspect:"
    echo "      cd $SRC && patch -p1 --dry-run -i <patch>"
    exit 1
fi
echo "    all patch markers present"

echo ""
echo ">>> Done. Next:"
echo "      ./xnu-build-arm64.sh --check     # verify toolchain"
echo "      ./xnu-build-arm64.sh             # build (needs macOS + cctools)"
echo ""
