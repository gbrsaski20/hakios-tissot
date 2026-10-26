#!/bin/bash
# ============================================================================
# tools/make-rufus-img.sh — Create a Rufus-flashable HakiOS-x86 USB image
#
# Usage: make-rufus-img.sh [output.img]
#
# Produces a raw disk image (.img) with:
#   - MBR partition table
#   - FAT32 EFI System Partition (ESP)
#   - /EFI/BOOT/BOOTX64.EFI   (copy of xnuloader.efi — UEFI fallback path)
#   - /EFI/HAKIOS/xnuloader.efi
#   - /EFI/HAKIOS/mach_kernel
#   - /EFI/HAKIOS/cmdline.txt
#
# Flash with Rufus:
#   1. Open Rufus
#   2. Select the .img file
#   3. Choose "DD Image" mode (not ISO mode)
#   4. Write to USB
#   5. Boot from USB (enable UEFI in BIOS)
#
# This script uses mtools (mformat/mcopy) with @@offset so it does NOT
# need mount/loop device — works inside WSL2.
# ============================================================================
set -e

# ---- Defaults ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT="${1:-$ROOT_DIR/prebuilt/hakios-x86.img}"

# Image geometry
IMG_SIZE=$((256 * 1024 * 1024))  # 256 MB total (room for real XNU kernel)
MBR_SIZE=512                     # MBR bootstrap + partition table
PART_START=$((1 * 1024 * 1024)) # Partition starts at 1 MiB (2048 sectors)
PART_SIZE=$((IMG_SIZE - PART_START))

# Default kernel command line
CMDLINE="cpus=2 display=1 input=1 disk=1 net=1 serial=1"

echo ""
echo "========================================"
echo "  HakiOS-x86 Rufus Image Builder"
echo "========================================"
echo "  Output:  $OUTPUT"
echo "  Size:    $((IMG_SIZE / 1024 / 1024)) MB"
echo ""

# ---- Find built artifacts ----
KERNEL=""
for f in \
    "$ROOT_DIR/prebuilt/mach.development.x86_64" \
    "$ROOT_DIR/prebuilt/mach.release.x86_64" \
    "$ROOT_DIR/prebuilt/mach.debug.x86_64" \
    "$ROOT_DIR/xnu-src/build/obj/DEVELOPMENT_X86_64/mach.development.hakios" \
    "$ROOT_DIR/xnu-src/build/obj/RELEASE_X86_64/mach.release.hakios"; do
    if [ -f "$f" ]; then
        KERNEL="$f"
        break
    fi
done

LOADER=""
for f in \
    "$ROOT_DIR/prebuilt/xnuloader.efi" \
    "$ROOT_DIR/xnuloader/build/xnuloader.efi"; do
    if [ -f "$f" ]; then
        LOADER="$f"
        break
    fi
done

if [ -z "$LOADER" ]; then
    echo "ERROR: xnuloader.efi not found."
    echo "       Run './xnuloader/build.sh' first, or 'make x86-open'."
    exit 1
fi

if [ -z "$KERNEL" ]; then
    echo "WARNING: mach_kernel not found. Creating image with loader only."
    echo "         The kernel will need to be added manually, or build with"
    echo "         'make x86-open' (needs XNU sources + cctools)."
    echo ""
    KERNEL="/dev/null"
fi

echo "  Loader:  $LOADER"
if [ "$KERNEL" != "/dev/null" ]; then
    echo "  Kernel:  $KERNEL"
else
    echo "  Kernel:  (none — loader-only image)"
fi
echo "  Cmdline: $CMDLINE"
echo ""

# ---- Check tools ----
missing=0
for tool in dd mformat mmd mcopy; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: '$tool' not found. Install mtools: apt install mtools"
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    exit 1
fi

# ---- Create output directory ----
mkdir -p "$(dirname "$OUTPUT")"

# ---- Step 1: Create the raw image file ----
echo ">>> [1/5] Creating raw image ($((IMG_SIZE / 1024 / 1024)) MB)..."
dd if=/dev/zero of="$OUTPUT" bs=1M count=$((IMG_SIZE / 1024 / 1024)) 2>/dev/null

# ---- Step 2: Write MBR partition table ----
echo ">>> [2/5] Writing MBR partition table..."

# We write a simple MBR with one partition entry:
# - Boot flag: 0x80 (active — harmless for UEFI, helps some firmwares)
# - Partition type: 0xEF (EFI System Partition)
# - Start LBA: 2048 (1 MiB)
# - Size: PART_SIZE / 512 sectors

# MBR partition table starts at offset 446 (446 bytes bootstrap + 4x16 bytes entries + 2 bytes signature)
# We only need entry 1 (first 16 bytes at offset 446)

START_SECTOR=$((PART_START / 512))
NUM_SECTORS=$((PART_SIZE / 512))

# Write partition entry using printf (byte-by-byte)
# Entry format (16 bytes):
#   byte 0:  boot flag (0x80 = active)
#   bytes 1-3: CHS start (use 0xFE, 0xFF, 0xFF = "use LBA")
#   byte 4:  partition type (0xEF = EFI System Partition)
#   bytes 5-7: CHS end (0xFE, 0xFF, 0xFF)
#   bytes 8-11: LBA start (little-endian 32-bit)
#   bytes 12-15: number of sectors (little-endian 32-bit)

# LBA start (little-endian)
LBA_HEX=$(printf '%08x' "$START_SECTOR")
LBA_B1=$((16#${LBA_HEX:6:2}))
LBA_B2=$((16#${LBA_HEX:4:2}))
LBA_B3=$((16#${LBA_HEX:2:2}))
LBA_B4=$((16#${LBA_HEX:0:2}))

# Sector count (little-endian)
SEC_HEX=$(printf '%08x' "$NUM_SECTORS")
SEC_B1=$((16#${SEC_HEX:6:2}))
SEC_B2=$((16#${SEC_HEX:4:2}))
SEC_B3=$((16#${SEC_HEX:2:2}))
SEC_B4=$((16#${SEC_HEX:0:2}))

# Write partition entry at offset 446
printf '\x80\xfe\xff\xff\xef\xfe\xff\xff' >> /tmp/hakios_mbr_entry.bin
printf "\\x$(printf '%02x' $LBA_B1)\\x$(printf '%02x' $LBA_B2)\\x$(printf '%02x' $LBA_B3)\\x$(printf '%02x' $LBA_B4)" >> /tmp/hakios_mbr_entry.bin
printf "\\x$(printf '%02x' $SEC_B1)\\x$(printf '%02x' $SEC_B2)\\x$(printf '%02x' $SEC_B3)\\x$(printf '%02x' $SEC_B4)" >> /tmp/hakios_mbr_entry.bin

# Write entry into the image at offset 446
dd if=/tmp/hakios_mbr_entry.bin of="$OUTPUT" bs=1 seek=446 conv=notrunc 2>/dev/null
rm -f /tmp/hakios_mbr_entry.bin

# Write MBR signature (0x55AA at offset 510)
printf '\x55\xaa' | dd of="$OUTPUT" bs=1 seek=510 conv=notrunc 2>/dev/null

echo "    Partition: start=LBA $START_SECTOR, sectors=$NUM_SECTORS"

# ---- Step 3: Format FAT32 partition (at offset) ----
echo ">>> [3/5] Formatting FAT32 partition..."

# Use mformat with @@offset to format at PART_START without mounting
# mformat -i <image>::@@<offset> -F -T <sectors> -h <heads> -s <sectors_per_track> -c <cluster_size> ::
mformat -i "$OUTPUT"@@$PART_START -F -T $NUM_SECTORS -h 16 -s 63 -c 2 ::

echo "    FAT32 formatted."

# ---- Step 4: Copy files ----
echo ">>> [4/5] Copying boot files..."

# Create directories
mmd -i "$OUTPUT"@@$PART_START ::/EFI
mmd -i "$OUTPUT"@@$PART_START ::/EFI/BOOT
mmd -i "$OUTPUT"@@$PART_START ::/EFI/HAKIOS

# Copy xnuloader.efi as BOOTX64.EFI (UEFI fallback path — critical for Rufus)
mcopy -i "$OUTPUT"@@$PART_START "$LOADER" ::/EFI/BOOT/BOOTX64.EFI
echo "    /EFI/BOOT/BOOTX64.EFI  <- xnuloader.efi (UEFI fallback)"

# Also copy as xnuloader.efi in HAKIOS dir (for xnuloader's own lookup)
mcopy -i "$OUTPUT"@@$PART_START "$LOADER" ::/EFI/HAKIOS/xnuloader.efi
echo "    /EFI/HAKIOS/xnuloader.efi"

# Copy mach_kernel if available
if [ "$KERNEL" != "/dev/null" ]; then
    mcopy -i "$OUTPUT"@@$PART_START "$KERNEL" ::/EFI/HAKIOS/mach_kernel
    echo "    /EFI/HAKIOS/mach_kernel"
fi

# Write cmdline.txt
echo -n "$CMDLINE" | mcopy -i "$OUTPUT"@@$PART_START - ::/EFI/HAKIOS/cmdline.txt
echo "    /EFI/HAKIOS/cmdline.txt"

# ---- Step 5: Verify ----
echo ">>> [5/5] Verifying image..."

echo "    Image size: $(du -h "$OUTPUT" | cut -f1)"
echo "    Partition listing:"
mdir -i "$OUTPUT"@@$PART_START ::/EFI/BOOT/ 2>/dev/null || true
mdir -i "$OUTPUT"@@$PART_START ::/EFI/HAKIOS/ 2>/dev/null || true

echo ""
echo "========================================"
echo "  Rufus image created successfully!"
echo "========================================"
echo ""
echo "  Output: $OUTPUT"
echo ""
echo "  To flash with Rufus:"
echo "    1. Download Rufus from https://rufus.ie"
echo "    2. Open Rufus, click SELECT, choose:"
echo "       $OUTPUT"
echo "    3. Set Partition scheme: GPT"
echo "    4. Set Target system: UEFI (non-CSM)"
echo "    5. Click START"
echo "    6. If Rufus asks, choose 'DD Image' mode (NOT ISO mode)"
echo "    7. Boot from USB (enable UEFI in BIOS)"
echo ""
echo "  Alternatively, flash with dd (Linux/WSL):"
echo "    dd if=$OUTPUT of=/dev/sdX bs=4M conv=fsync status=progress"
echo ""
