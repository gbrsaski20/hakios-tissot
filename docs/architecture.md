# HakiOS-x86 Architecture

## Overview

HakiOS-x86 ports the HakiOS research project from ARM64/Qualcomm to x86_64. The key differences:

| Aspect | HakiOS (ARM64) | HakiOS-x86 (x86_64) |
|--------|----------------|---------------------|
| Kernel source | XNU xnu-8796.121.2 (ARM64) | XNU xnu-8796.121.2 (X86_64) |
| Build config | DEVELOPMENT_ARM64_BCM2837 | DEVELOPMENT_X86_64 |
| Boot loader | UEFI (AArch64) | UEFI (x86_64 PE64) |
| Boot args | device tree from Android | ACPI + device tree from QEMU/UEFI |
| Device model | Qualcomm SoC (device tree) | PC platform (ACPI + PCI enumeration) |
| Drivers | Adreno GPU, UFS, modem, etc. | VGA, AHCI, E1000, HDA, etc. |
| Target | Physical phone + QEMU virt | Physical PC + QEMU q35 |

## Boot Flow

```
Power On
  |
  v
UEFI Firmware (OVMF in QEMU, BIOS/UEFI on real PC)
  |
  v
xnuloader.efi (our UEFI application, loaded by firmware)
  |
  |-- reads mach_kernel from ESP (EFI System Partition)
  |-- reads hakios.dtb (device tree) or uses ACPI
  |-- reads kernel command line
  |-- allocates memory for kernel + initrd
  |-- fills BootArgs_X86_64 structure
  |-- disables interrupts, sets up page tables (if needed)
  |-- jumps to kernel entry (i386_init / x86_64_init)
  |
  v
XNU kernel startup (pstart.c -> startup.c -> machine_init)
  |
  |-- reads BootArgs from xnuloader
  |-- parses command line
  |-- initializes PMAP, VM, scheduler
  |
  v
Platform Expert (hakios PE for x86_64)
  |
  |-- ACPI init or device tree walk
  |-- PCI enumeration
  |-- loads hakios drivers (display, input, disk, net, audio)
  |
  v
launchd / user space
```

## XNU x86_64 Build System

XNU natively supports building for X86_64:

```bash
make ARCH_CONFIGS=X86_64 KERNEL_CONFIGS=DEVELOPMENT \
     TARGET_CONFIGS= hakios-x86 \
     SDKROOT=macosx.internal
```

The `TARGET_CONFIGS` variable selects the platform. We define a new target `hakios-x86` in `xnu/files/MASTER.x86_64` that:
- Sets the platform to `hakios` instead of `APPLE` or ` GENERIC`
- Adds our driver source files
- Configures the build to produce `mach.development.hakios` (or similar)

## Device Tree vs ACPI

On ARM, HakiOS uses the device tree from Android. On x86_64, we have two options:

1. **ACPI** (preferred for real PC): XNU has an ACPI implementation. We patch it to recognize our platform.
2. **Device Tree** (for QEMU simplicity): We generate a minimal device tree that describes the QEMU q35 hardware. This is simpler but less authentic.

We support both. The `acpi=1` flag uses ACPI; `dt=1` uses device tree.

## Driver Architecture

Each driver is a single C file in `xnu/files/bsd/dev/hakios.*.c`:

```
hakios.display.c   — VGA framebuffer + Bochs VBE extensions (QEMU)
hakios.input.c     — i8042 keyboard/mouse controller + USB HID (future)
hakios.disk.c      — AHCI SATA controller + virtio-blk
hakios.net.c       — Intel E1000 (82540EM) + virtio-net
hakios.audio.c     — Intel High Definition Audio (HDA)
hakios.timer.c     — HPET + Local APIC timer + RTC
hakios.serial.c    — 16550 UART (COM1)
hakios.pci.c       — PCI configuration space access (conf1)
```

Each driver registers with the XNU device switch (`cdevsw` / `bdevsw`) and is available as `/dev/hakios_*`.

## Memory Layout (QEMU q35, 4GB RAM)

```
0x00000000 - 0x0009FFFF  Low memory (640KB)
0x000A0000 - 0x000BFFFF  VGA window
0x000C0000 - 0x000FFFFF  BIOS/UEFI shadow
0x00100000 - 0x........  Kernel loaded here by xnuloader
0x........ - 0x........  Kernel segments (text, data, bss)
0x........ - 0x........  Initrd / ramdisk
0x........ - 0xBFFFFFFF  Usable RAM
0xC0000000 - 0xFFFFFFFF  PCI hole (MMIO, BARs)
0x100000000+              High memory (>4GB, if present)
```

## BootArgs for x86_64

XNU uses `BootArgs` (also called `boot_args`) to pass information from the loader to the kernel. On x86_64, this is defined in `pexpert/x86/i386/bootargs.h`:

```c
typedef struct {
    uint16_t  Revision;
    uint16_t  Version;
    uint32_t  efiMode;
    uint32_t  CommandLineLength;
    uint32_t  CommandLine;
    uint32_t  MemoryMap;
    uint32_t  MemoryMapSize;
    uint32_t  MemoryMapDescriptorSize;
    uint32_t  MemoryMapDescriptorVersion;
    uint32_t  VideoType;
    uint32_t  VideoBaseAddr;
    uint32_t  VideoRowBytes;
    uint32_t  VideoHeight;
    uint32_t  VideoWidth;
    uint32_t  VideoDepth;
    uint64_t  efiRuntimeServicesPageStart;
    uint64_t  efiRuntimeServicesPageCount;
    uint64_t  efiRuntimeServicesVirtualPageTable;
    uint32_t  efiSystemTable;
    uint32_t  efiRuntimeServices;
    // ...
} BootArgs;
```

Our xnuloader fills this structure and passes its physical address to the kernel entry point.
