/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Serial Driver — 16550 UART (COM1/COM2)
 *
 * This driver provides serial console output for the XNU kernel
 * on x86_64. It uses the standard 16550-compatible UART present
 * at I/O ports 0x3F8 (COM1) and 0x2F8 (COM2).
 *
 * In QEMU, serial output appears on the console or can be redirected
 * to a file or pipe.
 *
 * APSL 2.0 — see NOTICE and COMPLIANCE.md.
 *
 * Numbers: National Semiconductor PC16550D datasheet, and the
 * standard IBM PC AT serial port assignments.
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/conf.h>
#include <sys/uio.h>
#include <sys/kernel.h>
#include <sys/tty.h>

#include "hakios_x86.h"

/* 16550 UART register offsets */
#define UART_RBR        0x00    /* Receive Buffer Register (read) */
#define UART_THR        0x00    /* Transmitter Holding Register (write) */
#define UART_IER        0x01    /* Interrupt Enable Register */
#define UART_IIR        0x02    /* Interrupt Identification Register (read) */
#define UART_FCR        0x02    /* FIFO Control Register (write) */
#define UART_LCR        0x03    /* Line Control Register */
#define UART_MCR        0x04    /* Modem Control Register */
#define UART_LSR        0x05    /* Line Status Register */
#define UART_MSR        0x06    /* Modem Status Register */
#define UART_SCR        0x07    /* Scratch Register */

/* LCR bits */
#define UART_LCR_DLAB    0x80   /* Divisor Latch Access Bit */
#define UART_LCR_8N1     0x03   /* 8 data bits, no parity, 1 stop bit */

/* LSR bits */
#define UART_LSR_DR      0x01   /* Data Ready */
#define UART_LSR_THRE    0x20   /* Transmit Holding Register Empty */
#define UART_LSR_TEMT    0x40   /* Transmitter Empty */

/* FCR bits */
#define UART_FCR_ENABLE  0x01   /* Enable FIFO */
#define UART_FCR_CLEAR_RX 0x02  /* Clear RX FIFO */
#define UART_FCR_CLEAR_TX 0x04  /* Clear TX FIFO */
#define UART_FCR_14BYTE  0xC0   /* 14-byte trigger level */

/* MCR bits */
#define UART_MCR_DTR     0x01   /* Data Terminal Ready */
#define UART_MCR_RTS     0x02   /* Request To Send */
#define UART_MCR_OUT2    0x08   /* OUT2 (enables interrupts) */

/* IER bits */
#define UART_IER_TX      0x02   /* Transmitter Holding Register Empty */
#define UART_IER_RX      0x01   /* Received Data Available */

/* Baud rate divisor values (for 115200 baud at 1.8432 MHz clock) */
#define UART_BAUD_115200  1
#define UART_BAUD_57600   2
#define UART_BAUD_38400   3
#define UART_BAUD_19200   6
#define UART_BAUD_9600    12

/* Active serial port */
static uint16_t hakios_serial_port = HAKIOS_SERIAL_COM1;

/* ============================================================================
 * UART register access
 * ============================================================================
 */

static inline uint8_t
uart_read(uint16_t port, uint8_t reg)
{
    return hakios_inb(port + reg);
}

static inline void
uart_write(uint16_t port, uint8_t reg, uint8_t val)
{
    hakios_outb(port + reg, val);
}

/* ============================================================================
 * Serial initialization
 * ============================================================================
 */

void
hakios_serial_init(uint16_t port)
{
    hakios_serial_port = port;

    /* Disable interrupts */
    uart_write(port, UART_IER, 0x00);

    /* Enable DLAB (set baud rate divisor) */
    uart_write(port, UART_LCR, UART_LCR_DLAB | UART_LCR_8N1);

    /* Set baud rate to 115200 (divisor = 1) */
    uart_write(port, 0x00, UART_BAUD_115200 & 0xFF);  /* Divisor low byte */
    uart_write(port, 0x01, (UART_BAUD_115200 >> 8) & 0xFF); /* High byte */

    /* Set 8 bits, no parity, 1 stop bit, disable DLAB */
    uart_write(port, UART_LCR, UART_LCR_8N1);

    /* Enable FIFO, clear them, 14-byte threshold */
    uart_write(port, UART_FCR, UART_FCR_ENABLE |
               UART_FCR_CLEAR_RX | UART_FCR_CLEAR_TX | UART_FCR_14BYTE);

    /* IRQs enabled, RTS/DSR set */
    uart_write(port, UART_MCR, UART_MCR_DTR | UART_MCR_RTS | UART_MCR_OUT2);
}

/* ============================================================================
 * Serial output
 * ============================================================================
 */

static int
hakios_serial_tx_ready(void)
{
    return uart_read(hakios_serial_port, UART_LSR) & UART_LSR_THRE;
}

void
hakios_serial_putc(char c)
{
    /* Wait for transmit holding register to be empty */
    int timeout = 100000;
    while (!hakios_serial_tx_ready() && timeout--)
        ;

    /* Write the character */
    uart_write(hakios_serial_port, UART_THR, (uint8_t)c);

    /* If newline, also send carriage return */
    if (c == '\n') {
        timeout = 100000;
        while (!hakios_serial_tx_ready() && timeout--)
            ;
        uart_write(hakios_serial_port, UART_THR, '\r');
    }
}

void
hakios_serial_puts(const char *str)
{
    if (!hakios_serial_port)
        return;
    while (*str) {
        hakios_serial_putc(*str);
        str++;
    }
}

void
hakios_serial_putbuf(const char *buf, int len)
{
    if (!hakios_serial_port)
        return;
    for (int i = 0; i < len; i++) {
        hakios_serial_putc(buf[i]);
    }
}

/* ============================================================================
 * Serial input
 * ============================================================================
 */

int
hakios_serial_rx_ready(void)
{
    return uart_read(hakios_serial_port, UART_LSR) & UART_LSR_DR;
}

char
hakios_serial_getc(void)
{
    /* Wait for data to be available */
    int timeout = 100000;
    while (!hakios_serial_rx_ready() && timeout--)
        ;

    if (!hakios_serial_rx_ready())
        return 0;

    return (char)uart_read(hakios_serial_port, UART_RBR);
}

int
hakios_serial_read(char *buf, int len)
{
    int count = 0;
    while (count < len && hakios_serial_rx_ready()) {
        buf[count] = (char)uart_read(hakios_serial_port, UART_RBR);
        count++;
    }
    return count;
}

/* ============================================================================
 * Hex dumping (for debugging)
 * ============================================================================
 */

void
hakios_serial_hexdump(const void *data, int len)
{
    const uint8_t *bytes = (const uint8_t *)data;
    char hex[3];

    for (int i = 0; i < len; i++) {
        if (i > 0 && (i % 16) == 0) {
            hakios_serial_puts("\n");
        }
        snprintf(hex, sizeof(hex), "%02X ", bytes[i]);
        hakios_serial_puts(hex);
    }
    if (len > 0 && (len % 16) != 0) {
        hakios_serial_puts("\n");
    }
}
