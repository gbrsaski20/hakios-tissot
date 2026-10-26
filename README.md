# HakiOS-x86

**Run the open-source XNU kernel on x86_64 PCs and in QEMU — like Bliss OS, but for Darwin/iOS user space instead of Android.**

HakiOS-x86 is a fork/port of the [HakiOS](https://github.com/oosexgang/hackios-xnu-kernel) research project, retargeted from ARM64/Qualcomm to **x86_64**. It runs Apple's open-source XNU kernel (xnu-8796.121.2) on standard PC hardware and in the QEMU `q35` machine, with custom drivers for the x86 platform, and optionally boots the iOS 16.5 user space on top.

Nothing is installed. The kernel and loader go into RAM — a reboot brings the PC back to its own OS. This is a research bench, not a daily driver.

## Why?

| | Bliss OS | HakiOS-x86 |
|---|---|---|
| Kernel | Linux (Android) | XNU (Darwin/iOS) |
| Architecture | x86_64 | x86_64 |
| User space | Android (AOSP) | iOS user space (optional) |
| Host | PC / QEMU | PC / QEMU |
| Approach | AOSP ported to x86 | XNU ported to x86, custom loader + drivers |

HakiOS-x86 is the "Bliss OS for iOS" — it takes the XNU kernel (which Apple publishes under APSL 2.0), ports it to x86_64 PC hardware, and boots it with a custom UEFI loader and custom x86 drivers. The stock iOS user space is optional and requires you to supply your own IPSW.

## What is in this repository

Only my code and my data:

- **`xnu/`** — the kernel: a patch to Apple's open-source XNU (`xnu/hakios-x86.patch`, APSL 2.0) and my x86 driver files (`xnu/files/`), laid over a fresh clone by `xnu/apply.sh`
- **`xnuloader/`** — the boot loader: a UEFI application for x86_64 that loads `mach_kernel` and boots XNU
- **`userland/`** — my programs and libraries (`src/`), the image build, launchd jobs
- **`sysimage/`** — scripts that fetch and unpack OS files from the IPSW (none of the files themselves)
- **`devices/pc-q35/`** — the PC device: QEMU q35 config, ACPI tables, device tree
- **`tools/`** — APFS, run scripts, QMI tests
- **`qemu/`** — running in QEMU
- **`docs/`** — notes, architecture, driver docs
- **`prebuilt/`** — the built kernel, loader and libraries

Not in the repository, never:
- Any file of iOS: no binary, image, cache, font, picture or screenshot
- Keys, certificates, activation, or anything that would make the PC pass as an iPhone to Apple's services

## Quick start in QEMU

Linux x86-64, about 12 GB of disk, `qemu-system-x86_64`, `edk2-x86_64` (OVMF).

```bash
git clone https://github.com/oosexgang/hackios-xnu-kernel.git hakios-x86
cd hakios-x86

# Build the open kernel (no IPSW, no iOS user space needed)
make x86-open

# Or build the full system (needs the IPSW, see below)
make x86-full

# Run in QEMU
make qemu-open          # open kernel + placeholder loader + tiny user space
# or
make qemu               # full iOS user space (needs IPSW)
```

The open path boots XNU, prints kernel messages to serial, and drops to a minimal shell. The full path boots the iOS user space.

## On a real PC

A PC with UEFI boot, the images from the build step, and a USB drive:

```bash
# Build the open kernel + loader
make x86-open

# Create a bootable USB
tools/make-boot-usb.sh /dev/sdX

# Boot from USB (or use the EFI shell)
# The loader goes into RAM, the system lives in RAM for the session
```

## Building from source

### Prerequisites

- Linux x86-64 host (Ubuntu 22.04+ or equivalent)
- `clang` (14+), `lld-link`, `ld`, `make`
- `qemu-system-x86_64`
- `7z` (7-Zip 23+), `lz4`
- For the full system: the iOS 16.5 IPSW (from Apple's public servers)

### Building the kernel (x86_64)

```bash
xnu/apply.sh             # XNU sources from Apple's GitHub + my changes -> xnu-src/
xnu-deps/setup.sh        # dependencies and tools
./xnu-build-x86.sh -j8   # -> xnu-src/.../BUILD/obj/DEVELOPMENT_X86_64/mach.development
```

XNU natively supports `X86_64` as a build architecture. The patch adds:
- x86_64 device tree / ACPI platform definitions
- Custom x86_64 drivers for QEMU q35 hardware
- Boot arguments and platform expert for the PC

### Building the loader

```bash
xnuloader/build.sh        # clang + lld-link, an EFI application (PE64)
```

The loader is a UEFI application (x86_64 PE) that:
1. Reads `mach_kernel` from the EFI System Partition
2. Reads the kernel command line
3. Sets up the boot arguments (BootArgs for x86_64)
4. Jumps to the kernel entry point

### Building the user space and images

```bash
REST=1 userland/build.sh   # APFS images: userland/root.apfs and userland/system.apfs
```

## Architecture

```
+-------------------------------------------------------------------+
|                        QEMU q35 / Real PC                          |
|  (Intel CPU, ICH9, virtio devices, VGA, AHCI, E1000)              |
+-------------------------------------------------------------------+
           |                    |                    |
+------------------+  +-------------------+  +------------------+
| xnuloader (UEFI) |  | mach_kernel (XNU) |  | user space       |
|  x86_64 PE64     |  |  DEVELOPMENT_     |  |  launchd,        |
|  loads kernel,   |->|  X86_64           |->|  backboardd,     |
|  sets BootArgs    |  |  + hakios drivers|  |  SpringBoard     |
+------------------+  +-------------------+  +------------------+
```

### Drivers (`xnu/files/bsd/dev/hakios.*.c`)

| Driver | File | Hardware |
|--------|------|----------|
| Display (VGA/bochs) | `hakios.display.c` | QEMU VGA, Bochs VBE |
| Input (keyboard/mouse) | `hakios.input.c` | i8042, PS/2, USB HID |
| Disk (AHCI/virtio) | `hakios.disk.c` | AHCI SATA, virtio-blk |
| Network (E1000/virtio) | `hakios.net.c` | Intel E1000, virtio-net |
| Audio (HDA) | `hakios.audio.c` | Intel HDA, AC97 |
| Timer (HPET/Local APIC) | `hakios.timer.c` | HPET, Local APIC, RTC |
| Serial | `hakios.serial.c` | 16550 UART |
| PCI | `hakios.pci.c` | PCI/PCIe config space |

## Kernel arguments

| Argument | What it does |
|----------|-------------|
| `cpus=N` | Number of CPU cores to use |
| `display=1` | VGA display driver |
| `input=1` | Keyboard and mouse input |
| `disk=1` | AHCI/virtio disk driver |
| `net=1` | E1000/virtio network driver |
| `audio=1` | HDA audio driver |
| `serial=1` | Serial console output |
| `var_store=1` | Keep /private/var across reboots |

## Status

| Works | Not yet |
|-------|---------|
| XNU kernel boots on x86_64 (QEMU q35) | iOS GUI (needs full user space) |
| Serial console, kernel messages | Metal rendering |
| VGA text/graphics mode | Bluetooth |
| Multi-core (SMP) | Wi-Fi (needs x86 Wi-Fi driver) |
| AHCI disk I/O | Audio (needs HDA driver work) |
| E1000 network | Full iOS app compatibility |
| Custom UEFI loader | |

## Independent, and Apple-free at the core

HakiOS-x86 is an independent research project. It is **not affiliated with or endorsed by Apple**. "iOS", "iPhone", "XNU" and "Apple" are named only to describe what the code works with. The core kernel, the boot loader and the open tools build and run with nothing of Apple's:

```bash
make qemu-open      # open kernel + placeholder loader + tiny raw-syscall user space, in QEMU
```

No IPSW, no iOS user space, no firmware. Booting the stock iOS user space is an optional path that needs the IPSW which you supply from your own device.

## Licenses

My code is under the license of the files it changes: the XNU patch under the Apple Public Source License 2.0 (Apple publishes XNU under it; the terms are met: changes are published as source, notices are kept), the rest as the file headers say. iOS, its images, Apple's trademarks belong to their owners, are not in this repository and are not distributed.

See `LEGAL.md`, `COMPLIANCE.md`, `THIRD_PARTY_LICENSES.md`, and `NOTICE` for details. None of this is legal advice.
