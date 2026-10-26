#!/bin/bash
# ============================================================================
# tools/make-boot-usb.sh — Create a bootable USB drive for HakiOS-x86
#
# Usage: make-boot-usb.sh /dev/sdX
#
# This formats the USB drive with a FAT32 EFI System Partition,
# installs xnuloader.efi, mach_kernel, and cmdline.txt, and
# registers it with the UEFI boot manager.
#
# WARNING: This DESTROYS all data on the target device!
# ============================================================================
set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <device>"
    echo "Example: $0 /dev/sdb"
    exit 1
fi

DEVICE="$1"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo ""
echo "========================================"
echo "WARNING: This will DESTROY all data on"
echo "         $DEVICE"
echo "========================================"
echo ""
read -p "Type YES to continue: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# Find the kernel and loader
KERNEL=""
for f in \
    "$ROOT_DIR/prebuilt/mach.development.x86_64" \
    "$ROOT_DIR/prebuilt/mach.release.x86_64" \
    "$ROOT_DIR/prebuilt/mach.debug.x86_64"; do
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

if [ -z "$KERNEL" ] || [ -z "$LOADER" ]; then
    echo "ERROR: Kernel or loader not found. Run 'make x86-open' first."
    exit 1
fi

echo ">>> Formatting $DEVICE with FAT32..."

# Create a single FAT32 partition
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart primary fat32 1MiB 100%
parted -s "$DEVICE" set 1 boot on

# Format the partition
PART="${DEVICE}1"
if [ ! -b "$PART" ]; then
    PART="${DEVICE}p1"
fi
mkfs.vfat -F32 "$PART"

# Mount
TEMP_MNT=$(mktemp -d)
mount "$PART" "$TEMP_MNT"

# Create EFI directory structure
mkdir -p "$TEMP_MNT/EFI/HAKIOS"

# Copy files
cp "$LOADER" "$TEMP_MNT/EFI/HAKIOS/xnuloader.efi"
cp "$KERNEL" "$TEMP_MNT/EFI/HAKIOS/mach_kernel"
echo "cpus=2 display=1 input=1 disk=1 net=1 serial=1" > \
    "$TEMP_MNT/EFI/HAKIOS/cmdline.txt"

# Unmount
umount "$TEMP_MNT"
rmdir "$TEMP_MNT"

echo ">>> Bootable USB created on $DEVICE"
echo ">>> Boot from USB to start HakiOS-x86"
