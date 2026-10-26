# HakiOS-x86 PC Device Configuration (devices/pc-q35)

This is the x86_64 equivalent of the ARM64 `devices/poco-x5-pro/`.
It describes the PC platform (QEMU q35) and provides the configuration
needed to boot on it.

## What lives here

| File | Purpose |
|------|---------|
| `README.md` | This file |
| `device-tree.dts` | Minimal device tree (optional, for dt=1 mode) |
| `acpi-override.aml` | ACPI table overrides (optional) |
| `make-esp.sh` | Script to create an ESP disk image for QEMU |
| `OVMF.fd` | OVMF UEFI firmware (not distributed, from your distro) |

## QEMU q35 hardware map

```
+--------------------------------------------------+
|                  QEMU q35 Machine                  |
|                                                    |
|  +----------+  +----------+  +----------+         |
|  | CPU 0    |  | CPU 1    |  | CPU N    |         |
|  | (APIC 0) |  | (APIC 1) |  | (APIC N) |         |
|  +----------+  +----------+  +----------+         |
|                                                    |
|  +----------------+  +----------------+            |
|  | Local APIC     |  | IOAPIC          |           |
|  | 0xFEE00000     |  | 0xFEC00000      |           |
|  +----------------+  +----------------+            |
|                                                    |
|  +----------------+  +----------------+            |
|  | HPET           |  | RTC             |           |
|  | 0xFED00000     |  | port 0x70/0x71  |           |
|  +----------------+  +----------------+            |
|                                                    |
|  +----------------+                                 |
|  | PCI Bus (conf1)|                                |
|  | 0x0CF8/0x0CFC  |                                |
|  +----------------+                                 |
|        |                                           |
|  +-----+-----+--+--+--+--+--+                     |
|  |     |     |  |  |  |  |  |                     |
| AHCI  HDA  VGA  E1000  USB  HPET  ...              |
| 00:1f.2 00:1b.0    00:03.0                         |
+--------------------------------------------------+
```

## Device Tree (optional)

While x86 normally uses ACPI for device discovery, we also provide
a minimal device tree for simplicity. Enable it with `dt=1` on the
kernel command line.

The device tree describes:
- CPU cores and their frequencies
- Memory layout
- APIC base addresses
- HPET address
- PCI bus root
- VGA framebuffer address

## Booting from USB (real PC)

```bash
# Create a bootable USB
tools/make-boot-usb.sh /dev/sdX

# Boot from USB
# Your PC's UEFI firmware should show "HakiOS-x86" in the boot menu
```

## Porting to a real PC

A port to a different PC is similar to the ARM64 phone port:

1. The ACPI tables come from the PC's own BIOS/UEFI — no code change needed
2. The drivers are shared — the same `hakios.*.c` files work on any PC
3. If the PC has different hardware (e.g., NVMe instead of AHCI),
   you add a new driver file and add it to the build

This is simpler than the ARM phone port because:
- ACPI is standardized across PCs
- PCI is standardized
- Most PCs use the same ISA I/O ports for keyboard, serial, RTC
