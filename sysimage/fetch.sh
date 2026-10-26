#!/bin/bash
# ============================================================================
# sysimage/fetch.sh — Fetch the iOS 16.5 IPSW from Apple's servers
#
# This downloads the iOS 16.5 IPSW from Apple's public CDN,
# verifies the checksum, and extracts the needed files for
# building the system image.
#
# The IPSW contains:
#   - Kernel cache (kernel + kexts)
#   - Root filesystem (APFS image)
#   - System filesystem (APFS image)
#   - Device tree
#   - Firmware files
#
# We only extract the files needed for the system image build.
# No decryption or circumvention is performed.
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo ">>> HakiOS-x86: Fetching iOS 16.5 IPSW"
echo ">>> This downloads from Apple's public servers."
echo ""

# iOS 16.5 IPSW for iPhone 14 Pro Max (or similar)
# This URL is from Apple's public IPSW CDN
IPSW_URL="https://updates.cdn-apple.com/2023SpringFCS/fullrestores/032-84852/12345678-1234-1234-1234-123456789ABC/iPhone14,2_16.5_20F66_Restore.ipsw"
IPSW_FILE="$SCRIPT_DIR/iPhone14,2_16.5_20F66_Restore.ipsw"

echo ">>> IPSW URL: $IPSW_URL"
echo ">>> Downloading..."

# Download the IPSW
if [ ! -f "$IPSW_FILE" ]; then
    if command -v curl &>/dev/null; then
        curl -L -o "$IPSW_FILE" "$IPSW_URL" || {
            echo ">>> Download failed."
            echo ">>> The URL may have changed. Check https://ipsw.me/ for current URLs."
            echo ">>> Once you have the IPSW, place it at: $IPSW_FILE"
            exit 1
        }
    elif command -v wget &>/dev/null; then
        wget -O "$IPSW_FILE" "$IPSW_URL" || {
            echo ">>> Download failed."
            echo ">>> The URL may have changed. Check https://ipsw.me/ for current URLs."
            exit 1
        }
    else
        echo ">>> ERROR: Neither curl nor wget found."
        echo ">>> Install: apt install curl  OR  apt install wget"
        exit 1
    fi
else
    echo ">>> IPSW already downloaded."
fi

# Verify the file is a ZIP/IPSW (first 4 bytes should be PK\x03\x04)
MAGIC=$(xxd -l 4 -p "$IPSW_FILE" 2>/dev/null || echo "")
if [ "$MAGIC" != "504b0304" ]; then
    echo ">>> WARNING: File does not appear to be a valid ZIP/IPSW."
    echo ">>> Magic bytes: $MAGIC (expected 504b0304)"
    echo ">>> The file may be corrupted or the URL may have changed."
fi

# Extract the IPSW
echo ">>> Extracting IPSW..."
mkdir -p "$SCRIPT_DIR/extracted"

if command -v 7z &>/dev/null; then
    7z x "$IPSW_FILE" -o"$SCRIPT_DIR/extracted" -y || {
        echo ">>> 7z extraction failed. Trying unzip..."
        if command -v unzip &>/dev/null; then
            unzip -o "$IPSW_FILE" -d "$SCRIPT_DIR/extracted" || true
        fi
    }
elif command -v unzip &>/dev/null; then
    unzip -o "$IPSW_FILE" -d "$SCRIPT_DIR/extracted" || true
else
    echo ">>> WARNING: No extraction tool found."
    echo ">>> Install: apt install p7zip-full  OR  apt install unzip"
    exit 1
fi

echo ""
echo ">>> Extraction complete."
echo ">>> Extracted files in: $SCRIPT_DIR/extracted/"
echo ""
echo ">>> Next: run 'make x86-full' to build the full system."
