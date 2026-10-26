/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 PCI Driver — PCI/PCIe Configuration Space Access
 *
 * This driver provides PCI configuration space access for the XNU
 * kernel on x86_64. It uses the standard PCI conf1 mechanism:
 *   - Write address to port 0x0CF8
 *   - Read/write data at port 0x0CFC
 *
 * This is the standard PC PCI configuration mechanism. It allows
 * us to enumerate devices, read their class/vendor/device IDs,
 * configure BARs (Base Address Registers), and enable
 * memory space / bus mastering.
 *
 * APSL 2.0 — see NOTICE and COMPLIANCE.md.
 *
 * Numbers: PCI Local Bus Specification 3.0, section 3.1
 * (Configuration Mechanism #1).
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/conf.h>
#include <sys/kernel.h>
#include <sys/malloc.h>

#include "hakios_x86.h"

/* ============================================================================
 * PCI Configuration Mechanism #1
 * ============================================================================
 *
 * The address port (0x0CF8) uses this format:
 *   bit 31    : Enable bit (must be 1)
 *   bits 23-16: Bus number
 *   bits 15-11: Device (slot) number
 *   bits 10-8 : Function number
 *   bits 7-2  : Register offset (word-aligned)
 *   bits 1-0  : Always 0
 *
 * The data port (0x0CFC) reads/writes 32-bit values at the
 * offset specified in the address port.
 */

#define PCI_ADDR(bus, dev, func, off) \
    (HAKIOS_PCI_CONF_ENABLE | \
     ((bus) << 16) | ((dev) << 11) | ((func) << 8) | ((off) & 0xFC))

/* ============================================================================
 * PCI config space read/write
 * ============================================================================
 */

uint8_t
hakios_pci_read8(int bus, int dev, int func, int offset)
{
    uint32_t addr = PCI_ADDR(bus, dev, func, offset & ~3);
    uint32_t shift = (offset & 3) * 8;

    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr);
    uint32_t val = hakios_inl(HAKIOS_PCI_CONF_DATA);

    return (uint8_t)(val >> shift);
}

uint16_t
hakios_pci_read16(int bus, int dev, int func, int offset)
{
    uint32_t addr = PCI_ADDR(bus, dev, func, offset & ~3);
    uint32_t shift = (offset & 2) * 8;

    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr);
    uint32_t val = hakios_inl(HAKIOS_PCI_CONF_DATA);

    return (uint16_t)(val >> shift);
}

uint32_t
hakios_pci_read32(int bus, int dev, int func, int offset)
{
    uint32_t addr = PCI_ADDR(bus, dev, func, offset);

    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr);
    return hakios_inl(HAKIOS_PCI_CONF_DATA);
}

void
hakios_pci_write8(int bus, int dev, int func, int offset, uint8_t value)
{
    /* Read-modify-write for byte access */
    uint32_t addr = PCI_ADDR(bus, dev, func, offset & ~3);
    uint32_t shift = (offset & 3) * 8;
    uint32_t mask = ~(0xFF << shift);

    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr);
    uint32_t old = hakios_inl(HAKIOS_PCI_CONF_DATA);
    uint32_t new = (old & mask) | ((uint32_t)value << shift);

    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr);
    hakios_outl(HAKIOS_PCI_CONF_DATA, new);
}

void
hakios_pci_write16(int bus, int dev, int func, int offset, uint16_t value)
{
    uint32_t addr = PCI_ADDR(bus, dev, func, offset & ~3);
    uint32_t shift = (offset & 2) * 8;
    uint32_t mask = ~(0xFFFF << shift);

    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr);
    uint32_t old = hakios_inl(HAKIOS_PCI_CONF_DATA);
    uint32_t new = (old & mask) | ((uint32_t)value << shift);

    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr);
    hakios_outl(HAKIOS_PCI_CONF_DATA, new);
}

void
hakios_pci_write32(int bus, int dev, int func, int offset, uint32_t value)
{
    uint32_t addr = PCI_ADDR(bus, dev, func, offset);

    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr);
    hakios_outl(HAKIOS_PCI_CONF_DATA, value);
}

/* ============================================================================
 * PCI device information
 * ============================================================================
 */

/* PCI class descriptions */
static const char *
hakios_pci_class_name(uint8_t class_code)
{
    switch (class_code) {
        case 0x00: return "Unclassified";
        case 0x01: return "Mass Storage";
        case 0x02: return "Network";
        case 0x03: return "Display";
        case 0x04: return "Multimedia";
        case 0x05: return "Memory";
        case 0x06: return "Bridge";
        case 0x07: return "Communication";
        case 0x08: return "Generic System Peripheral";
        case 0x09: return "Input Device";
        case 0x0A: return "Docking Station";
        case 0x0B: return "Processor";
        case 0x0C: return "Serial Bus";
        case 0x0D: return "Wireless";
        case 0x0E: return "Intelligent Controller";
        case 0x0F: return "Satellite Communication";
        case 0x10: return "Encryption";
        case 0x11: return "Signal Processing";
        default:   return "Unknown";
    }
}

/* ============================================================================
 * PCI enumeration
 * ============================================================================
 */

void
hakios_pci_init(void)
{
    hakios_serial_puts("HakiOS-x86: initializing PCI bus...\n");

    /* Enable PCI conf1 mechanism */
    /* On most PCs, it's already enabled by the BIOS/UEFI firmware */

    /* Enumerate all devices */
    int device_count = 0;

    for (int bus = 0; bus < 256; bus++) {
        for (int dev = 0; dev < 32; dev++) {
            for (int func = 0; func < 8; func++) {
                uint32_t id = hakios_pci_read32(bus, dev, func, 0x00);
                uint16_t vendor = id & 0xFFFF;
                uint16_t device_id = (id >> 16) & 0xFFFF;

                if (vendor == 0xFFFF || vendor == 0x0000)
                    continue;

                uint32_t class_val = hakios_pci_read32(bus, dev, func, 0x08);
                uint8_t base_class = (class_val >> 24) & 0xFF;
                uint8_t sub_class = (class_val >> 16) & 0xFF;
                uint8_t interface = (class_val >> 8) & 0xFF;
                uint8_t revision = class_val & 0xFF;

                const char *class_name = hakios_pci_class_name(base_class);

                char msg[128];
                snprintf(msg, sizeof(msg),
                    "HakiOS-x86: PCI %02x:%02x.%d  %04x:%04x  %s (0x%02x/0x%02x/0x%02x) rev=%02x\n",
                    bus, dev, func, vendor, device_id, class_name,
                    base_class, sub_class, interface, revision);
                hakios_serial_puts(msg);

                device_count++;

                /* If function 0 has no multi-function bit, skip other functions */
                if (func == 0) {
                    uint16_t header_type =
                        hakios_pci_read16(bus, dev, func, 0x0E);
                    if (!(header_type & 0x80))
                        break; /* Not multi-function, skip funcs 1-7 */
                }
            }
        }
    }

    char count_msg[64];
    snprintf(count_msg, sizeof(count_msg),
             "HakiOS-x86: PCI enumeration complete, %d devices found\n",
             device_count);
    hakios_serial_puts(count_msg);
}

/* ============================================================================
 * PCI BAR (Base Address Register) configuration
 * ============================================================================
 */

uint32_t
hakios_pci_get_bar(int bus, int dev, int func, int bar_index)
{
    int offset = 0x10 + bar_index * 4;
    return hakios_pci_read32(bus, dev, func, offset);
}

uint32_t
hakios_pci_get_bar_size(int bus, int dev, int func, int bar_index)
{
    int offset = 0x10 + bar_index * 4;

    /* Save original value */
    uint32_t original = hakios_pci_read32(bus, dev, func, offset);

    /* Write all 1s to get the size mask */
    hakios_pci_write32(bus, dev, func, offset, 0xFFFFFFFF);
    uint32_t size_val = hakios_pci_read32(bus, dev, func, offset);

    /* Restore original value */
    hakios_pci_write32(bus, dev, func, offset, original);

    /* For I/O space (bit 0 = 1), size is in low 2 bits */
    if (size_val & 0x01) {
        /* I/O space */
        size_val &= ~0x03; /* Clear type bits */
        if (size_val == 0)
            return 0;
        return ~(size_val) + 1;
    } else {
        /* Memory space */
        if (size_val & 0x08) {
            /* 64-bit memory space (prefetchable) */
            size_val &= ~0x0F;
        } else {
            size_val &= ~0x0F;
        }
        if (size_val == 0)
            return 0;
        return ~(size_val) + 1;
    }
}

void
hakios_pci_enable_device(int bus, int dev, int func)
{
    /* Read current command register */
    uint16_t cmd = hakios_pci_read16(bus, dev, func, 0x04);

    /* Enable: memory space (bit 1), I/O space (bit 0), bus master (bit 2) */
    cmd |= 0x07;

    hakios_pci_write16(bus, dev, func, 0x04, cmd);
}

void
hakios_pci_set_bar(int bus, int dev, int func, int bar_index, uint32_t value)
{
    int offset = 0x10 + bar_index * 4;
    hakios_pci_write32(bus, dev, func, offset, value);
}
