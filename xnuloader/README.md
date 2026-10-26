# xnuloader — HakiOS-x86 Boot Loader

## What is this?

The HakiOS-x86 boot loader is a UEFI x86_64 application (PE64) that
loads the XNU kernel and boots it on a PC. It is the x86_64
equivalent of the ARM64 xnuloader from the original HakiOS.

## How it works

```
UEFI firmware (OVMF in QEMU)
  |
  v
xnuloader.efi (loaded from ESP)
  |
  |-- reads \EFI\HAKIOS\mach_kernel
  |-- reads \EFI\HAKIOS\cmdline.txt
  |-- gets EFI memory map
  |-- fills BootArgs structure
  |-- calls ExitBootServices()
  |-- jumps to kernel entry point
  |
  v
XNU kernel (mach_kernel)
```

## Building

```bash
xnuloader/build.sh
```

Requirements:
- clang (with UEFI target support)
- lld-link (from LLVM's lld)

The build produces `build/xnuloader.efi`.

## Installing on a USB drive

```bash
# Format a USB drive with FAT32 (EFI System Partition)
mkfs.vfat -F32 /dev/sdX1

# Mount it
mount /dev/sdX1 /mnt

# Create the HakiOS directory
mkdir -p /mnt/EFI/HAKIOS

# Copy the boot loader
cp xnuloader/build/xnuloader.efi /mnt/EFI/HAKIOS/

# Copy the kernel
cp prebuilt/mach.development.x86_64 /mnt/EFI/HAKIOS/mach_kernel

# Create a command line file
echo "cpus=2 display=1 input=1 disk=1 net=1 serial=1" > \
    /mnt/EFI/HAKIOS/cmdline.txt

# Register with the UEFI boot menu (on a real PC)
efibootmgr -c -d /dev/sdX -p 1 -L "HakiOS-x86" \
    -l '\EFI\HAKIOS\xnuloader.efi'
```

## UEFI variables

The loader reads the kernel command line from `cmdline.txt` on the
ESP. You can also set it as a UEFI variable:

```bash
# Set kernel command line as a UEFI variable
efivar -w -n ... -a "cpus=4 display=1 disk=1 net=1"
```

## Files

| File | Purpose |
|------|---------|
| `main.c` | UEFI entry point (`efi_main`) |
| `xnuloader.h` | UEFI type definitions (no EDK2) |
| `build.sh` | Build script (clang + lld-link) |
| `identity.h` | Device identity (generated at build time) |
