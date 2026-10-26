#!/bin/bash
# ============================================================================
# tools/make-esp.sh — Create an EFI System Partition (ESP) disk image
#
# Usage: make-esp.sh <output.img> <xnuloader.efi> <mach_kernel> [cmdline]
#
# Creates a FAT32 disk image with:
#   /EFI/HAKIOS/xnuloader.efi
#   /EFI/HAKIOS/mach_kernel
#   /EFI/HAKIOS/cmdline.txt
# ============================================================================
set -e

if [ $# -lt 3 ]; then
    echo "Usage: $0 <output.img> <xnuloader.efi> <mach_kernel> [cmdline]"
    exit 1
fi

OUTPUT="$1"
LOADER="$2"
KERNEL="$3"
CMDLINE="${4:-cpus=2 display=1 input=1 disk=1 net=1 serial=1}"

IMG_SIZE=$((50 * 1024 * 1024))  # 50 MB

echo ">>> Creating ESP image: $OUTPUT ($((IMG_SIZE / 1024 / 1024)) MB)"

# ---- Create the image file ----
dd if=/dev/zero of="$OUTPUT" bs=1M count=$((IMG_SIZE / 1024 / 1024)) 2>/dev/null

# ---- Format as FAT32 ----
if command -v mkfs.vfat &>/dev/null; then
    mkfs.vfat -F32 "$OUTPUT" 2>/dev/null || {
        echo ">>> mkfs.vfat failed, trying mtools..."
    }
elif command -v mformat &>/dev/null; then
    mformat -i "$OUTPUT" -F -T $((IMG_SIZE / 512)) - ::
else
    echo ">>> ERROR: No FAT formatting tool found."
    echo ">>> Install: apt install dosfstools  OR  apt install mtools"
    exit 1
fi

# ---- Copy files ----
if command -v mcopy &>/dev/null; then
    echo ">>> Copying files with mtools..."
    mmd -i "$OUTPUT" ::/EFI
    mmd -i "$OUTPUT" ::/EFI/HAKIOS
    mcopy -i "$OUTPUT" "$LOADER" ::/EFI/HAKIOS/xnuloader.efi
    mcopy -i "$OUTPUT" "$KERNEL" ::/EFI/HAKIOS/mach_kernel
    echo -n "$CMDLINE" | mcopy -i "$OUTPUT" - ::/EFI/HAKIOS/cmdline.txt
elif command -v mnt &>/dev/null; then
    echo ">>> Mounting and copying files..."
    TEMP_MNT=$(mktemp -d)
    mount -o loop "$OUTPUT" "$TEMP_MNT"
    mkdir -p "$TEMP_MNT/EFI/HAKIOS"
    cp "$LOADER" "$TEMP_MNT/EFI/HAKIOS/xnuloader.efi"
    cp "$KERNEL" "$TEMP_MNT/EFI/HAKIOS/mach_kernel"
    echo -n "$CMDLINE" > "$TEMP_MNT/EFI/HAKIOS/cmdline.txt"
    umount "$TEMP_MNT"
    rmdir "$TEMP_MNT"
else
    echo ">>> ERROR: Cannot copy files. Install mtools or have mount+loop support."
    exit 1
fi

echo ">>> ESP image created: $OUTPUT"
echo ">>> Contents:"
echo ">>>   /EFI/HAKIOS/xnuloader.efi"
echo ">>>   /EFI/HAKIOS/mach_kernel"
echo ">>>   /EFI/HAKIOS/cmdline.txt"
