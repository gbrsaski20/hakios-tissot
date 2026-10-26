/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Platform Driver — ACPI + Platform Expert Glue
 *
 * This file ties together the platform expert and the individual
 * drivers. It initializes ACPI (if available) and dispatches to
 * the individual driver init functions based on the kernel
 * command line.
 *
 * APSL 2.0 — see NOTICE and COMPLIANCE.md.
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/conf.h>
#include <sys/malloc.h>

#include "hakios_x86.h"

/* ============================================================================
 * ACPI support (simplified)
 * ============================================================================
 *
 * ACPI tables are found by scanning memory for the RSDP signature.
 * On x86_64 PCs (and QEMU), the firmware provides ACPI tables.
 *
 * The RSDP (Root System Description Pointer) contains a pointer to
 * the RSDT or XSDT, which lists all other ACPI tables.
 */

/* ACPI signatures */
#define ACPI_RSDP_SIG     "RSD PTR "  /* with trailing space */
#define ACPI_RSDT_SIG     "RSDT"
#define ACPI_XSDT_SIG     "XSDT"
#define ACPI_FADT_SIG     "FACP"
#define ACPI_DSDT_SIG     "DSDT"
#define ACPI_MADT_SIG     "APIC"
#define ACPI_HPET_SIG     "HPET"
#define ACPI_MCFG_SIG     "MCFG"

/* RSDP structure (ACPI 1.0) */
struct acpi_rsdp {
    char     signature[8];   /* "RSD PTR " */
    uint8_t  checksum;
    char     oem_id[6];
    uint8_t  revision;
    uint32_t rsdt_address;   /* Physical address of RSDT */
    /* ACPI 2.0+ extensions: */
    uint32_t length;
    uint64_t xsdt_address;
    uint8_t  extended_checksum;
    uint8_t  reserved[3];
} __attribute__((packed));

/* ACPI table header (common to all tables) */
struct acpi_table_header {
    char     signature[4];
    uint32_t length;
    uint8_t  revision;
    uint8_t  checksum;
    char     oem_id[6];
    char     oem_table_id[8];
    uint32_t oem_revision;
    char     creator_id[4];
    uint32_t creator_revision;
} __attribute__((packed));

/* RSDT (Root System Description Table) */
struct acpi_rsdt {
    struct acpi_table_header header;
    uint32_t entries[];   /* Array of table pointers */
} __attribute__((packed));

/* MADT (Multiple APIC Description Table) */
struct acpi_madt {
    struct acpi_table_header header;
    uint32_t lapic_address;
    uint32_t flags;
    uint8_t  entries[];
} __attribute__((packed));

/* HPET table */
struct acpi_hpet {
    struct acpi_table_header header;
    uint8_t  revision;
    uint8_t  info;
    uint16_t pci_vendor_id;
    struct {
        uint8_t  space_id;
        uint8_t  bit_width;
        uint8_t  bit_offset;
        uint8_t  access_size;
        uint64_t address;
    } address;
    uint8_t  hpet_number;
    uint16_t min_tick;
    uint8_t  page_protection;
} __attribute__((packed));

/* Global ACPI state */
static struct acpi_rsdp *hakios_acpi_rsdp = NULL;
static struct acpi_rsdt *hakios_acpi_rsdt = NULL;
static uint32_t hakios_acpi_lapic_addr = 0;
static uint32_t hakios_acpi_hpet_addr = 0;

/* ============================================================================
 * Find RSDP
 * ============================================================================
 *
 * The RSDP is found in one of two places:
 *   1. In the EBDA (Extended BIOS Data Area), searched in the first 1KB
 *      starting from the EBDA base (at 0x0000040E)
 *   2. In the BIOS ROM area, from 0xE0000 to 0xFFFFF, 16-byte aligned
 */

static int
hakios_acpi_find_rsdp(void)
{
    /* Try EBDA first */
    /* EBDA base is stored at 0x0000040E (2 bytes, segment) */
    /* segment * 16 = physical address */
    volatile uint16_t *ebda_ptr = (volatile uint16_t *)0x0000040E;
    uint16_t ebda_seg = *ebda_ptr;
    if (ebda_seg != 0) {
        uintptr_t ebda_addr = (uintptr_t)ebda_seg << 4;
        volatile char *p = (volatile char *)ebda_addr;
        for (int i = 0; i < 1024; i += 16) {
            if (memcmp((const void *)(p + i), ACPI_RSDP_SIG, 8) == 0) {
                hakios_acpi_rsdp = (struct acpi_rsdp *)(p + i);
                return 0;
            }
        }
    }

    /* Search BIOS ROM area 0xE0000 - 0xFFFFF */
    for (uintptr_t addr = 0xE0000; addr < 0x100000; addr += 16) {
        if (memcmp((const void *)addr, ACPI_RSDP_SIG, 8) == 0) {
            hakios_acpi_rsdp = (struct acpi_rsdp *)addr;
            return 0;
        }
    }

    return -1; /* Not found */
}

/* ============================================================================
 * Find ACPI table by signature
 * ============================================================================
 */

static struct acpi_table_header *
hakios_acpi_find_table(const char *sig)
{
    if (!hakios_acpi_rsdt)
        return NULL;

    /* Number of entries in RSDT */
    int num_entries =
        (hakios_acpi_rsdt->header.length - sizeof(struct acpi_table_header))
        / sizeof(uint32_t);

    for (int i = 0; i < num_entries; i++) {
        struct acpi_table_header *table =
            (struct acpi_table_header *)(uintptr_t)
            hakios_acpi_rsdt->entries[i];

        if (memcmp(table->signature, sig, 4) == 0)
            return table;
    }

    return NULL;
}

/* ============================================================================
 * ACPI initialization
 * ============================================================================
 */

void
hakios_acpi_init(void)
{
    hakios_serial_puts("HakiOS-x86: initializing ACPI...\n");

    if (hakios_acpi_find_rsdp() != 0) {
        hakios_serial_puts("HakiOS-x86: RSDP not found, using defaults\n");
        /* Use default addresses */
        hakios_lapic_init(HAKIOS_LAPIC_BASE);
        hakios_ioapic_init(HAKIOS_IOAPIC_BASE);
        hakios_hpet_init(HAKIOS_HPET_BASE);
        return;
    }

    char msg[64];
    snprintf(msg, sizeof(msg),
             "HakiOS-x86: RSDP at %p, rev=%d\n",
             (void *)hakios_acpi_rsdp, hakios_acpi_rsdp->revision);
    hakios_serial_puts(msg);

    /* Get RSDT */
    if (hakios_acpi_rsdp->rsdt_address != 0) {
        hakios_acpi_rsdt = (struct acpi_rsdt *)
            (uintptr_t)hakios_acpi_rsdp->rsdt_address;

        char msg2[64];
        snprintf(msg2, sizeof(msg2),
                 "HakiOS-x86: RSDT at %p, %d entries\n",
                 (void *)hakios_acpi_rsdt,
                 (int)((hakios_acpi_rsdt->header.length -
                        sizeof(struct acpi_table_header)) /
                       sizeof(uint32_t)));
        hakios_serial_puts(msg2);
    }

    /* Find MADT (for LAPIC address) */
    struct acpi_madt *madt =
        (struct acpi_madt *)hakios_acpi_find_table(ACPI_MADT_SIG);
    if (madt) {
        hakios_acpi_lapic_addr = madt->lapic_address;
        if (hakios_acpi_lapic_addr == 0)
            hakios_acpi_lapic_addr = HAKIOS_LAPIC_BASE;

        char msg3[64];
        snprintf(msg3, sizeof(msg3),
                 "HakiOS-x86: LAPIC at 0x%x\n",
                 hakios_acpi_lapic_addr);
        hakios_serial_puts(msg3);
    } else {
        hakios_acpi_lapic_addr = HAKIOS_LAPIC_BASE;
    }

    /* Find HPET table */
    struct acpi_hpet *hpet_table =
        (struct acpi_hpet *)hakios_acpi_find_table(ACPI_HPET_SIG);
    if (hpet_table) {
        hakios_acpi_hpet_addr = (uint32_t)hpet_table->address.address;
        if (hakios_acpi_hpet_addr == 0)
            hakios_acpi_hpet_addr = HAKIOS_HPET_BASE;

        char msg4[64];
        snprintf(msg4, sizeof(msg4),
                 "HakiOS-x86: HPET at 0x%x\n",
                 hakios_acpi_hpet_addr);
        hakios_serial_puts(msg4);
    } else {
        hakios_acpi_hpet_addr = HAKIOS_HPET_BASE;
    }

    hakios_serial_puts("HakiOS-x86: ACPI initialized\n");
}

/* ============================================================================
 * Platform init (called from platform expert)
 * ============================================================================
 */

void
hakios_platform_init(void)
{
    hakios_serial_puts("HakiOS-x86: platform expert init\n");

    /* Initialize PCI bus */
    hakios_pci_init();

    /* Initialize ACPI if available */
    hakios_acpi_init();

    /* Initialize HPET timer */
    hakios_hpet_init(hakios_acpi_hpet_addr);

    /* Initialize Local APIC and IOAPIC */
    hakios_lapic_init(hakios_acpi_lapic_addr);
    hakios_ioapic_init(HAKIOS_IOAPIC_BASE);

    /* Initialize RTC */
    hakios_rtc_init();

    hakios_serial_puts("HakiOS-x86: platform init complete\n");
}

/* ============================================================================
 * Simple strtoul (standalone, no libc)
 * ============================================================================
 */

unsigned long
hakios_simple_strtoul(const char *cp, char **endp, unsigned int base)
{
    unsigned long result = 0;

    if (base == 0) {
        if (cp[0] == '0' && (cp[1] == 'x' || cp[1] == 'X')) {
            base = 16;
            cp += 2;
        } else {
            base = 10;
        }
    }

    while (*cp) {
        int digit;
        if (*cp >= '0' && *cp <= '9')
            digit = *cp - '0';
        else if (*cp >= 'a' && *cp <= 'f')
            digit = *cp - 'a' + 10;
        else if (*cp >= 'A' && *cp <= 'F')
            digit = *cp - 'A' + 10;
        else
            break;

        if (digit >= (int)base)
            break;

        result = result * base + digit;
        cp++;
    }

    if (endp)
        *endp = (char *)cp;

    return result;
}
