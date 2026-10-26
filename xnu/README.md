#!/bin/bash
# ============================================================================
# xnu/README.md — About the XNU kernel in HakiOS-x86
# ============================================================================

# XNU Kernel (HakiOS-x86)

## What we change

The XNU kernel (xnu-8796.121.2, published by Apple under APSL 2.0) already
supports x86_64 as a build architecture. The changes in HakiOS-x86 are:

1. **Platform Expert**: A new platform expert for the PC/x86_64 environment
   that uses ACPI and PCI for device discovery (instead of the device tree
   used on ARM).

2. **Drivers**: Custom drivers for standard PC hardware:
   - VGA/Bochs VBE display
   - i8042 keyboard/mouse
   - AHCI SATA and virtio-blk disk
   - Intel E1000 and virtio-net network
   - Intel HDA audio
   - HPET/Local APIC timer
   - 16550 UART serial
   - PCI configuration space

3. **Boot arguments**: Extended the boot argument parser to understand
   HakiOS-x86 specific arguments (display, input, disk, net, audio, serial).

4. **Device tree support**: While x86_64 normally uses ACPI, we also
   support a minimal device tree for simpler QEMU configuration.

## How to build

```bash
# 1. Apply the patch to a fresh XNU clone
xnu/apply.sh

# 2. Set up dependencies
xnu-deps/setup.sh

# 3. Build
./xnu-build-x86.sh -j8 -c DEVELOPMENT
```

The build produces `mach.development` (or `mach.release`, `mach.debug`)
in the XNU build output directory. It is copied to `prebuilt/`.

## Files

| File | Purpose |
|------|---------|
| `hakios-x86.patch` | Patch applied on top of Apple's XNU |
| `apply.sh` | Clone XNU and apply the patch |
| `files/bsd/dev/hakios.*.c` | Our x86_64 device drivers |
| `files/MASTER.x86_64` | Build configuration for the HakiOS target |
| `files/pexpert/x86/hakios_platform.c` | Platform expert for x86_64 |

## XNU x86_64 build anatomy

XNU's build system for x86_64 uses:

```
ARCH_CONFIGS=X86_64
KERNEL_CONFIGS=DEVELOPMENT
TARGET_CONFIGS=hakios     (our custom target)
```

The `TARGET_CONFIGS` selects a file in `config/` that defines platform-
specific settings. We created `config/hakios.x86_64`.

## Boot flow on x86_64

1. UEFI firmware (OVMF in QEMU) loads
2. UEFI starts our `xnuloader.efi` from the EFI System Partition
3. xnuloader reads `mach_kernel` and the kernel command line
4. xnuloader fills `BootArgs` and jumps to the kernel entry
5. XNU's `i386_init` / `x86_64_start` runs
6. Platform expert initializes ACPI / PCI
7. Drivers load
8. User space starts
