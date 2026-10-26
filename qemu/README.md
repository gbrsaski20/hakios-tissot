# HakiOS-x86 QEMU Configuration

## Machine: q35

We use the QEMU `q35` machine type, which emulates the Intel Q35
chipset (ICH9 southbridge). This is the modern PC platform.

### Key components emulated by q35:

| Component | QEMU Device | PCI Slot | Notes |
|-----------|-------------|----------|-------|
| CPU | qemu64 | — | x86_64, multi-core |
| AHCI SATA | ich9-ahci | 00:1f.2 | 6 SATA ports |
| HDA Audio | intel-hda | 00:1b.0 | Intel HDA controller |
| USB | ich9-usb-ehci | 00:1d.0 | USB 2.0 EHCI |
| VGA | std | — | VGA + Bochs VBE |
| NIC | e1000 | — | Intel 82540EM |
| RTC | mc146818 | — | CMOS RTC |
| HPET | hpet | — | High Precision Event Timer |
| APIC | ioapic | — | I/O APIC |
| PCI bus | pci-host | — | PCI/PCIe config space |

## Firmware: OVMF

We use OVMF (Open Virtual Machine Firmware), the open-source UEFI
firmware for QEMU.

- On Debian/Ubuntu: `apt install edk2-ovmf`
- On Arch: `pacman -S edk2-ovmf`
- On Fedora: `dnf install edk2-ovmf`

The firmware file is typically at:
- `/usr/share/OVMF/OVMF_CODE.fd`
- `/usr/share/edk2-ovmf/OVMF_CODE.fd`

## Running

```bash
# Open mode (no IPSW, no iOS user space)
make qemu-open

# Full mode (with iOS user space)
make qemu

# Custom QEMU options
qemu/run-x86.sh 600 --open -display none -smp 4 -m 8192
```

### QEMU keyboard shortcuts (in GTK display)

| Key | Action |
|-----|--------|
| Ctrl-Alt | Release mouse grab |
| Ctrl-Alt-G | Toggle guest keyboard grab |
| Ctrl-Alt-F | Toggle full screen |

### Serial console

Serial output goes to the terminal (stdout). Use `-display none` for
headless operation with serial only.
