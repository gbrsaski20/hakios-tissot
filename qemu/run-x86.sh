#!/bin/bash
# ============================================================================
# qemu/run-x86.sh — Run HakiOS-x86 in QEMU (q35 machine, x86_64)
#
# Usage:
#   qemu/run-x86.sh [SECS] [--open] [QEMU_ARGS...]
#
# The QEMU q35 machine is the modern PC chipset emulation.
# It provides:
#   - Intel CPU (x86_64)
#   - ICH9 southbridge (AHCI SATA, HDA, USB, etc.)
#   - PCI bus (for E1000 NIC, virtio devices)
#   - VGA display
#   - OVMF UEFI firmware
#
# This is the x86_64 equivalent of qemu/run-ios.sh from HakiOS ARM.
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
SECS=1200
OPEN_MODE=0
QEMU_DISPLAY="gtk"
QEMU_MEM=4096
QEMU_CPUS=2
QEMU_FW=""

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --open)
            OPEN_MODE=1
            shift
            ;;
        -display)
            QEMU_DISPLAY="$2"
            shift 2
            ;;
        -m)
            QEMU_MEM="$2"
            shift 2
            ;;
        -smp)
            QEMU_CPUS="$2"
            shift 2
            ;;
        -fw)
            QEMU_FW="$2"
            shift 2
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                SECS="$1"
            fi
            shift
            ;;
    esac
done

# ---- Find OVMF firmware ----
OVMF=""
for f in \
    "/usr/share/OVMF/OVMF_CODE.fd" \
    "/usr/share/edk2-ovmf/OVMF_CODE.fd" \
    "/usr/share/ovmf/OVMF.fd" \
    "/usr/share/qemu/OVMF.fd" \
    "/usr/lib/ovmf/OVMF.fd" \
    "$ROOT_DIR/devices/pc-q35/OVMF.fd"; do
    if [ -f "$f" ]; then
        OVMF="$f"
        break
    fi
done

if [ -z "$OVMF" ] && [ -n "$QEMU_FW" ]; then
    OVMF="$QEMU_FW"
fi

# ---- Find the kernel ----
KERNEL=""
for f in \
    "$ROOT_DIR/prebuilt/mach.development.x86_64" \
    "$ROOT_DIR/prebuilt/mach.release.x86_64" \
    "$ROOT_DIR/prebuilt/mach.debug.x86_64" \
    "$ROOT_DIR/prebuilt/mach_kernel"; do
    if [ -f "$f" ]; then
        KERNEL="$f"
        break
    fi
done

# ---- Find the loader ----
LOADER=""
for f in \
    "$ROOT_DIR/prebuilt/xnuloader.efi" \
    "$ROOT_DIR/xnuloader/build/xnuloader.efi"; do
    if [ -f "$f" ]; then
        LOADER="$f"
        break
    fi
done

# ---- Build QEMU arguments ----
QEMU_ARGS=(
    -machine q35
    -cpu qemu64
    -smp "$QEMU_CPUS"
    -m "$QEMU_MEM"
    -serial mon:stdio
    -display "$QEMU_DISPLAY"
    -no-reboot
)

# Add OVMF firmware if available
if [ -n "$OVMF" ]; then
    echo ">>> Using OVMF firmware: $OVMF"
    QEMU_ARGS+=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF")
else
    echo ">>> WARNING: OVMF firmware not found. UEFI boot will fail."
    echo ">>> Install: apt install edk2-ovmf (or ovmf)"
    echo ">>> Or set -fw /path/to/OVMF.fd"
fi

# ---- Set up the disk image ----
DISK_IMG="$ROOT_DIR/devices/pc-q35/disk.img"
ESP_IMG="$ROOT_DIR/devices/pc-q35/esp.img"

if [ "$OPEN_MODE" = "1" ]; then
    # Open mode: try to boot the kernel directly
    if [ -n "$KERNEL" ]; then
        echo ">>> Open mode: booting kernel directly"
        echo ">>> Kernel: $KERNEL"
        echo ">>> Session: ${SECS}s"

        # In open mode, we can try -kernel (bypass UEFI for simplicity)
        CMDLINE="cpus=$QEMU_CPUS display=1 input=1 disk=1 net=1 serial=1"
        QEMU_ARGS+=(
            -kernel "$KERNEL"
            -append "$CMDLINE"
        )
    else
        echo ">>> ERROR: No kernel found in prebuilt/"
        echo ">>> Run 'make x86-open' first."
        exit 1
    fi
else
    # Full mode: boot via UEFI loader from ESP
    if [ -n "$LOADER" ]; then
        echo ">>> Full mode: booting via xnuloader.efi"
        echo ">>> Loader: $LOADER"

        # We need a FAT ESP image with xnuloader.efi and mach_kernel
        # Create it if it doesn't exist
        if [ ! -f "$ESP_IMG" ]; then
            echo ">>> Creating ESP image..."
            "$ROOT_DIR/tools/make-esp.sh" "$ESP_IMG" "$LOADER" "$KERNEL"
        fi

        QEMU_ARGS+=(
            -drive "file=$ESP_IMG,format=raw,if=virtio"
        )

        # Also add the system disk image if it exists
        if [ -f "$DISK_IMG" ]; then
            QEMU_ARGS+=(
                -drive "file=$DISK_IMG,format=raw,if=ahci"
            )
        fi

        # Add the APFS root image if it exists
        if [ -f "$ROOT_DIR/userland/root.apfs" ]; then
            QEMU_ARGS+=(
                -drive "file=$ROOT_DIR/userland/root.apfs,format=raw,if=virtio"
            )
        fi
    else
        echo ">>> ERROR: No boot loader found."
        echo ">>> Run 'make x86-open' or 'make x86-full' first."
        exit 1
    fi
fi

# ---- Add network (E1000) ----
QEMU_ARGS+=(
    -netdev user,id=net0
    -device e1000,netdev=net0
)

# ---- Add audio (HDA) ----
QEMU_ARGS+=(
    -device intel-hda
    -device hda-output
)

# ---- Add VGA ----
QEMU_ARGS+=(
    -vga std
)

# ---- Run QEMU ----
echo ""
echo ">>> Starting QEMU (session: ${SECS}s)"
echo ">>> Ctrl-A H to exit QEMU"
echo ">>> Ctrl-A C for QEMU monitor"
echo ""

# Run QEMU with a timeout
if command -v timeout &>/dev/null; then
    timeout "$SECS" qemu-system-x86_64 "${QEMU_ARGS[@]}" || true
else
    qemu-system-x86_64 "${QEMU_ARGS[@]}" &
    QEMU_PID=$!
    (sleep "$SECS" && kill $QEMU_PID) 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
fi

echo ""
echo ">>> QEMU session ended"
