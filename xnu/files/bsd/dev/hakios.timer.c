/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Timer Driver — HPET + Local APIC + RTC
 *
 * This driver provides timing services for the XNU kernel on x86_64:
 *
 *   1. HPET (High-Precision Event Timer) at MMIO 0xFED00000
 *      — The standard PC timer, replaces the 8253 PIT
 *   2. Local APIC Timer
 *      — Per-CPU timer for scheduling ticks
 *   3. RTC (Real Time Clock) at I/O 0x70/0x71
 *      — CMOS clock for wall-clock time
 *
 * APSL 2.0 — see NOTICE and COMPLIANCE.md.
 *
 * Numbers: Intel HPET specification, Intel Local APIC documentation
 * (IA-32 Intel Architecture Software Developer's Manual Volume 3A).
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/conf.h>
#include <sys/kernel.h>
#include <sys/clock.h>

#include "hakios_x86.h"

/* ============================================================================
 * HPET (High Precision Event Timer)
 * ============================================================================
 *
 * The HPET is a memory-mapped timer block at 0xFED00000 (QEMU q35 default).
 * It provides:
 *   - A main counter (64-bit, counts up)
 *   - Up to 32 comparators/timers (can generate interrupts)
 *
 * The frequency is reported in the General Capabilities register.
 */

/* HPET register offsets */
#define HPET_CAP_ID      0x000    /* General Capabilities and ID */
#define HPET_CFG         0x010    /* General Configuration */
#define HPET_ISR         0x020    /* General Interrupt Status */
#define HPET_COUNTER     0x0F0    /* Main Counter Value */
#define HPET_CFG_ENABLE  0x001    /* Global Enable bit */

/* Timer N registers (offset = 0x100 + N * 0x20) */
#define HPET_TN_CAP     0x00    /* Timer N Capabilities */
#define HPET_TN_CFG     0x04    /* Timer N Configuration */
#define HPET_TN_CMP     0x08    /* Timer N Comparator */
#define HPET_TN_ROUTE   0x10    /* Timer N Interrupt Route */

/* Timer configuration bits */
#define HPET_TN_INT_ENB   0x00000004  /* Interrupt Enable */
#define HPET_TN_TYPE      0x00000008  /* 1 = periodic, 0 = one-shot */
#define HPET_TN_32BIT     0x00000100  /* 1 = 32-bit mode */

static volatile uint8_t *hpet_base = NULL;
static uint32_t hpet_frequency = 0;  /* Hz */
static uint64_t hpet_offset = 0;     /* Counter value at boot */

/* ============================================================================
 * Local APIC
 * ============================================================================
 *
 * The Local APIC is a per-CPU interrupt controller at MMIO 0xFEE00000.
 * It provides:
 *   - A timer (counts down from an initial value)
 *   - Inter-processor interrupts (IPI)
 *   - Task priority
 *
 * For XNU, the Local APIC timer drives the scheduler tick.
 */

/* Local APIC register offsets */
#define LAPIC_ID          0x020    /* APIC ID */
#define LAPIC_VER         0x030    /* APIC Version */
#define LAPIC_TPR         0x080    /* Task Priority */
#define LAPIC_EOI         0x0B0    /* End of Interrupt */
#define LAPIC_LDR         0x0D0    /* Logical Destination */
#define LAPIC_DFR         0x0E0    /* Destination Format */
#define LAPIC_SVR         0x0F0    /* Spurious Vector Register */
#define LAPIC_ICR         0x300    /* Interrupt Command Register */
#define LAPIC_LVT_TIMER   0x320    /* LVT Timer */
#define LAPIC_LVT_LINT0   0x350    /* LVT LINT0 */
#define LAPIC_LVT_LINT1   0x360    /* LVT LINT1 */
#define LAPIC_LVT_ERR     0x370    /* LVT Error */
#define LAPIC_INIT_COUNT  0x380    /* Initial Count (Timer) */
#define LAPIC_CURR_COUNT  0x390    /* Current Count (Timer) */
#define LAPIC_DIV_CONFIG  0x3E0    /* Divide Configuration */

/* Spurious vector register bits */
#define LAPIC_SVR_ENABLE  0x00000100

/* LVT timer bits */
#define LAPIC_LVT_PERIODIC 0x00020000
#define LAPIC_LVT_MASKED   0x00010000

static volatile uint8_t *lapic_base = NULL;

/* ============================================================================
 * RTC (Real Time Clock)
 * ============================================================================
 *
 * The RTC is accessed via CMOS ports 0x70 (index) and 0x71 (data).
 * It provides wall-clock time and date.
 */

/* RTC CMOS register offsets */
#define RTC_SECONDS      0x00
#define RTC_MINUTES      0x02
#define RTC_HOURS        0x04
#define RTC_WEEKDAY      0x06
#define RTC_DAY          0x07
#define RTC_MONTH        0x08
#define RTC_YEAR         0x09
#define RTC_STATUS_A      0x0A
#define RTC_STATUS_B      0x0B

/* Status B flags */
#define RTC_SB_24HR      0x02    /* 24-hour mode */
#define RTC_SB_BINARY    0x04    /* Binary mode (not BCD) */

static int rtc_binary_mode = 0;
static int rtc_24hr_mode = 0;

/* ============================================================================
 * HPET functions
 * ============================================================================
 */

static uint8_t
hpet_read8(uint32_t reg)
{
    return *(volatile uint8_t *)(hpet_base + reg);
}

static uint32_t
hpet_read32(uint32_t reg)
{
    return *(volatile uint32_t *)(hpet_base + reg);
}

static void
hpet_write32(uint32_t reg, uint32_t val)
{
    *(volatile uint32_t *)(hpet_base + reg) = val;
}

static uint64_t
hpet_read64(uint32_t reg)
{
    return *(volatile uint64_t *)(hpet_base + reg);
}

void
hakios_hpet_init(uint32_t base_addr)
{
    hpet_base = (volatile uint8_t *)(uintptr_t)base_addr;

    /* Read capabilities: bits 32-63 contain the period (femtoseconds) */
    uint64_t cap = hpet_read64(HPET_CAP_ID);
    uint32_t period = (cap >> 32) & 0xFFFFFFFF;

    if (period > 0) {
        hpet_frequency = 1000000000000000ULL / period;
    } else {
        hpet_frequency = 14318180; /* Default ~14.3MHz */
    }

    /* Enable HPET */
    hpet_write32(HPET_CFG, 0);
    hpet_write64(HPET_COUNTER, 0); /* Reset main counter */
    hpet_write32(HPET_CFG, HPET_CFG_ENABLE);

    hpet_offset = 0;

    char msg[64];
    snprintf(msg, sizeof(msg),
             "HakiOS-x86: HPET initialized, freq=%u Hz\n",
             hpet_frequency);
    hakios_serial_puts(msg);
}

uint64_t
hakios_hpet_read(void)
{
    if (!hpet_base)
        return 0;
    return hpet_read64(HPET_COUNTER);
}

uint64_t
hakios_hpet_to_ns(uint64_t hpet_ticks)
{
    /* Convert HPET ticks to nanoseconds */
    if (hpet_frequency == 0)
        return 0;
    return hpet_ticks * 1000000000ULL / hpet_frequency;
}

/* ============================================================================
 * Local APIC functions
 * ============================================================================
 */

static void
lapic_write(uint32_t reg, uint32_t val)
{
    *(volatile uint32_t *)(lapic_base + reg) = val;
}

static uint32_t
lapic_read(uint32_t reg)
{
    return *(volatile uint32_t *)(lapic_base + reg);
}

void
hakios_lapic_init(uint32_t base_addr)
{
    lapic_base = (volatile uint8_t *)(uintptr_t)base_addr;

    /* Enable the Local APIC by setting the spurious vector register */
    /* Use a high vector number (0xFF) to avoid conflicts */
    lapic_write(LAPIC_SVR, LAPIC_SVR_ENABLE | 0xFF);

    /* Mask LINT0 and LINT1 (we use the IOAPIC instead) */
    lapic_write(LAPIC_LVT_LINT0, LAPIC_LVT_MASKED);
    lapic_write(LAPIC_LVT_LINT1, LAPIC_LVT_MASKED);

    /* Set the timer to periodic mode */
    lapic_write(LAPIC_LVT_TIMER, LAPIC_LVT_PERIODIC | 0x20);

    /* Set divide value to 1 (no division) */
    lapic_write(LAPIC_DIV_CONFIG, 0x0B);

    /* Set initial count for ~100Hz (10ms tick) */
    /* APIC frequency = bus frequency / divide */
    /* For QEMU, the bus frequency is typically ~1GHz */
    /* 1GHz / 100 = 10000000 */
    lapic_write(LAPIC_INIT_COUNT, 10000000);

    hakios_serial_puts("HakiOS-x86: Local APIC initialized\n");
}

void
hakios_lapic_eoi(void)
{
    if (lapic_base)
        lapic_write(LAPIC_EOI, 0);
}

uint32_t
hakios_lapic_id(void)
{
    if (!lapic_base)
        return 0;
    return lapic_read(LAPIC_ID) >> 24;
}

/* ============================================================================
 * IOAPIC functions
 * ============================================================================
 */

#define IOAPIC_REG_INDEX  0x00
#define IOAPIC_REG_DATA   0x10
#define IOAPIC_REG_EOI    0x40

static volatile uint8_t *ioapic_base = NULL;

static void
ioapic_write(uint32_t reg, uint32_t val)
{
    *(volatile uint32_t *)(ioapic_base + IOAPIC_REG_INDEX) = reg;
    *(volatile uint32_t *)(ioapic_base + IOAPIC_REG_DATA) = val;
}

static uint32_t
ioapic_read(uint32_t reg)
{
    *(volatile uint32_t *)(ioapic_base + IOAPIC_REG_INDEX) = reg;
    return *(volatile uint32_t *)(ioapic_base + IOAPIC_REG_DATA);
}

void
hakios_ioapic_init(uint32_t base_addr)
{
    ioapic_base = (volatile uint8_t *)(uintptr_t)base_addr;

    /* Read IOAPIC version to determine number of pins */
    uint32_t ver = ioapic_read(0x01);
    int max_pins = (ver >> 16) & 0xFF;

    /* Mask all interrupts initially */
    for (int i = 0; i < max_pins; i++) {
        /* Redirection table entry (2x 32-bit registers per pin) */
        /* Offset 0x10 + 2*i for low word, 0x11 + 2*i for high word */
        ioapic_write(0x10 + 2 * i, 0x00010000); /* Masked */
        ioapic_write(0x11 + 2 * i, 0); /* Destination = 0 */
    }

    hakios_serial_puts("HakiOS-x86: IOAPIC initialized\n");
}

void
hakios_ioapic_route(int irq, int vector, int cpu)
{
    if (!ioapic_base)
        return;

    /* Unmask and set up the redirection entry */
    uint32_t low = vector | 0x00008000; /* Fixed delivery, edge-triggered */
    /* For level-triggered: low |= 0x00008000 | 0x00004000; */

    ioapic_write(0x10 + 2 * irq, low);
    ioapic_write(0x11 + 2 * irq, (uint32_t)cpu << 24);
}

/* ============================================================================
 * RTC functions
 * ============================================================================
 */

static uint8_t
rtc_read(uint8_t reg)
{
    hakios_outb(HAKIOS_RTC_PORT_INDEX, reg);
    return hakios_inb(HAKIOS_RTC_PORT_DATA);
}

static void
rtc_write(uint8_t reg, uint8_t val)
{
    hakios_outb(HAKIOS_RTC_PORT_INDEX, reg);
    hakios_outb(HAKIOS_RTC_PORT_DATA, val);
}

void
hakios_rtc_init(void)
{
    /* Read status B to determine format */
    uint8_t status_b = rtc_read(RTC_STATUS_B);
    rtc_24hr_mode = (status_b & RTC_SB_24HR) ? 1 : 0;
    rtc_binary_mode = (status_b & RTC_SB_BINARY) ? 1 : 0;

    /* Ensure 24-hour mode and binary mode for simplicity */
    if (!rtc_24hr_mode || !rtc_binary_mode) {
        rtc_write(RTC_STATUS_B, RTC_SB_24HR | RTC_SB_BINARY);
        rtc_24hr_mode = 1;
        rtc_binary_mode = 1;
    }

    hakios_serial_puts("HakiOS-x86: RTC initialized\n");
}

static uint8_t
rtc_bcd_to_bin(uint8_t bcd)
{
    if (rtc_binary_mode)
        return bcd;
    return ((bcd >> 4) & 0x0F) * 10 + (bcd & 0x0F);
}

void
hakios_rtc_get_time(int *hour, int *min, int *sec)
{
    /* Wait for update-in-progress to clear */
    while (rtc_read(RTC_STATUS_A) & 0x80)
        ;

    *sec = rtc_bcd_to_bin(rtc_read(RTC_SECONDS));
    *min = rtc_bcd_to_bin(rtc_read(RTC_MINUTES));
    uint8_t h = rtc_read(RTC_HOURS);
    if (!rtc_24hr_mode && (h & 0x80)) {
        /* PM in 12-hour mode */
        h = rtc_bcd_to_bin(h & 0x7F) + 12;
    } else {
        h = rtc_bcd_to_bin(h);
    }
    *hour = h;
}

void
hakios_rtc_get_date(int *year, int *month, int *day)
{
    while (rtc_read(RTC_STATUS_A) & 0x80)
        ;

    *day = rtc_bcd_to_bin(rtc_read(RTC_DAY));
    *month = rtc_bcd_to_bin(rtc_read(RTC_MONTH));
    *year = rtc_bcd_to_bin(rtc_read(RTC_YEAR));
    /* RTC only stores 2-digit year; assume 2000+ */
    *year += 2000;
}
