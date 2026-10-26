/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Input Driver — i8042 keyboard/mouse controller
 *
 * This driver provides keyboard and mouse input for the XNU kernel
 * on x86_64. It uses the standard i8042 PS/2 controller present in
 * all PC-compatible systems.
 *
 * In QEMU, this is emulated as the standard PC keyboard controller.
 *
 * APSL 2.0 — see NOTICE and COMPLIANCE.md.
 *
 * Numbers: Standard PC ISA I/O ports documented in the Intel 82806AA
 * (ICH) datasheet and the i8042 datasheet.
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/conf.h>
#include <sys/uio.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/systm.h>

#include "hakios_x86.h"

/* i8042 status register bits */
#define KBD_STATUS_OUTBUF      0x01   /* Output buffer full (data available) */
#define KBD_STATUS_INBUF       0x02   /* Input buffer full (data not read yet) */
#define KBD_STATUS_MOUSE       0x20   /* Data from mouse, not keyboard */
#define KBD_STATUS_TIMEOUT     0x40
#define KBD_STATUS_PARITY     0x80

/* i8042 commands */
#define KBD_CMD_READ_MODE      0x20   /* Read mode byte */
#define KBD_CMD_WRITE_MODE     0x60   /* Write mode byte */
#define KBD_CMD_DISABLE_MOUSE  0xA7
#define KBD_CMD_ENABLE_MOUSE   0xA8
#define KBD_CMD_DISABLE_KBD    0xAD
#define KBD_CMD_ENABLE_KBD     0xAE

/* i8042 mode bits */
#define KBD_MODE_KBD_INT       0x01
#define KBD_MODE_MOUSE_INT     0x02
#define KBD_MODE_SYS           0x04
#define KBD_MODE_KBD_DISABLE   0x10
#define KBD_MODE_MOUSE_DISABLE 0x20
#define KBD_MODE_TRANSLATE     0x40

/* Keyboard controller data port and status port */
#define KBD_DATA_PORT          HAKIOS_KBD_DATA
#define KBD_STATUS_PORT        HAKIOS_KBD_STATUS
#define KBD_COMMAND_PORT        HAKIOS_KBD_COMMAND

/* Scan code set 1 (default for PS/2 keyboards in QEMU) */

/* Ring buffer for keyboard input */
#define KBD_BUF_SIZE 256
static struct {
    uint8_t buf[KBD_BUF_SIZE];
    int head;
    int tail;
    int count;
} hakios_kbd_buf;

/* Ring buffer for mouse input */
#define MOUSE_BUF_SIZE 256
static struct {
    uint8_t buf[MOUSE_BUF_SIZE];
    int head;
    int tail;
    int count;
} hakios_mouse_buf;

/* Current keyboard modifiers */
static int hakios_kbd_shift = 0;
static int hakios_kbd_ctrl = 0;
static int hakios_kbd_alt = 0;
static int hakios_kbd_capslock = 0;

/* ============================================================================
 * Ring buffer helpers
 * ============================================================================
 */

static void
kbd_buf_push(uint8_t scancode)
{
    if (hakios_kbd_buf.count < KBD_BUF_SIZE) {
        hakios_kbd_buf.buf[hakios_kbd_buf.tail] = scancode;
        hakios_kbd_buf.tail = (hakios_kbd_buf.tail + 1) % KBD_BUF_SIZE;
        hakios_kbd_buf.count++;
    }
}

static uint8_t
kbd_buf_pop(void)
{
    uint8_t sc = 0;
    if (hakios_kbd_buf.count > 0) {
        sc = hakios_kbd_buf.buf[hakios_kbd_buf.head];
        hakios_kbd_buf.head = (hakios_kbd_buf.head + 1) % KBD_BUF_SIZE;
        hakios_kbd_buf.count--;
    }
    return sc;
}

static void
mouse_buf_push(uint8_t data)
{
    if (hakios_mouse_buf.count < MOUSE_BUF_SIZE) {
        hakios_mouse_buf.buf[hakios_mouse_buf.tail] = data;
        hakios_mouse_buf.tail = (hakios_mouse_buf.tail + 1) % MOUSE_BUF_SIZE;
        hakios_mouse_buf.count++;
    }
}

/* ============================================================================
 * i8042 controller access
 * ============================================================================
 */

static int
kbd_wait_for_input(void)
{
    int timeout = 10000;
    while ((hakios_inb(KBD_STATUS_PORT) & KBD_STATUS_INBUF) && timeout--)
        ;
    return timeout >= 0;
}

static int
kbd_wait_for_output(void)
{
    int timeout = 10000;
    while (!(hakios_inb(KBD_STATUS_PORT) & KBD_STATUS_OUTBUF) && timeout--)
        ;
    return timeout >= 0;
}

static uint8_t
kbd_read_data(void)
{
    if (kbd_wait_for_output())
        return hakios_inb(KBD_DATA_PORT);
    return 0;
}

static void
kbd_write_command(uint8_t cmd)
{
    if (kbd_wait_for_input())
        hakios_outb(KBD_COMMAND_PORT, cmd);
}

static void
kbd_write_data(uint8_t data)
{
    if (kbd_wait_for_input())
        hakios_outb(KBD_DATA_PORT, data);
}

/* ============================================================================
 * Keyboard interrupt handler
 * ============================================================================
 */

static void
hakios_kbd_interrupt(void)
{
    uint8_t status = hakios_inb(KBD_STATUS_PORT);

    while (status & KBD_STATUS_OUTBUF) {
        uint8_t data = hakios_inb(KBD_DATA_PORT);

        if (status & KBD_STATUS_MOUSE) {
            /* Mouse data */
            mouse_buf_push(data);
        } else {
            /* Keyboard scan code */
            uint8_t sc = data;

            /* Handle extended keys (prefix 0xE0) */
            /* Handle key release (bit 7 set) */
            int released = (sc & 0x80) ? 1 : 0;
            uint8_t base = sc & 0x7F;

            /* Track modifier state */
            switch (base) {
                case 0x2A: /* Left Shift */
                case 0x36: /* Right Shift */
                    hakios_kbd_shift = !released;
                    break;
                case 0x1D: /* Ctrl */
                    hakios_kbd_ctrl = !released;
                    break;
                case 0x38: /* Alt */
                    hakios_kbd_alt = !released;
                    break;
                case 0x3A: /* Caps Lock */
                    if (!released)
                        hakios_kbd_capslock = !hakios_kbd_capslock;
                    break;
            }

            kbd_buf_push(sc);
        }

        status = hakios_inb(KBD_STATUS_PORT);
    }
}

/* ============================================================================
 * Scancode to ASCII conversion (Set 1)
 * ============================================================================
 */

static const uint8_t scancode_to_ascii[128] = {
    /* 0x00 */ 0,    0x1B, '1',  '2',  '3',  '4',  '5',  '6',   /* esc, 1-6 */
    /* 0x08 */ '7',  '8',  '9',  '0',  '-',  '=',  0x08, '\t',  /* 7-0, -,=, bksp, tab */
    /* 0x10 */ 'q',  'w',  'e',  'r',  't',  'y',  'u',  'i',   /* q-i */
    /* 0x18 */ 'o',  'p',  '[',  ']',  '\n', 0,    'a',  's',   /* o-p, [,], enter, lctrl, a-s */
    /* 0x20 */ 'd',  'f',  'g',  'h',  'j',  'k',  'l',  ';',   /* d-; */
    /* 0x28 */ '\'', '`',  0,    '\\', 'z',  'x',  'c',  'v',   /* ', `, lshift, \, z-v */
    /* 0x30 */ 'b',  'n',  'm',  ',',  '.',  '/',  0,    '*',   /* b-/, rshift, * */
    /* 0x38 */ 0,    ' ',  0,    0,    0,    0,    0,    0,     /* alt, space, ... */
    /* 0x40 */ 0,    0,    0,    0,    0,    0,    0,    '7',
    /* 0x48 */ '8',  '9',  '-',  '4',  '5',  '6',  '+', '1',
    /* 0x50 */ '2',  '3',  '0',  '.',  0,    0,    0,    0,
    /* 0x58 */ 0,    0,    0,    0,    0,    0,    0,    0,
    /* 0x60 */ 0,    0,    0,    0,    0,    0,    0,    0,
    /* 0x68 */ 0,    0,    0,    0,    0,    0,    0,    0,
    /* 0x70 */ 0,    0,    0,    0,    0,    0,    0,    0,
    /* 0x78 */ 0,    0,    0,    0,    0,    0,    0,    0,
};

static char
hakios_kbd_scancode_to_ascii(uint8_t sc)
{
    uint8_t base = sc & 0x7F;
    if (base >= 128)
        return 0;
    char c = scancode_to_ascii[base];
    if (!c)
        return 0;
    /* Apply shift for letters */
    if (hakios_kbd_shift || hakios_kbd_capslock) {
        if (c >= 'a' && c <= 'z')
            c -= 32;
    }
    return c;
}

/* ============================================================================
 * Public API
 * ============================================================================
 */

void
hakios_input_init(void)
{
    /* Reset ring buffers */
    hakios_kbd_buf.head = hakios_kbd_buf.tail = hakios_kbd_buf.count = 0;
    hakios_mouse_buf.head = hakios_mouse_buf.tail = hakios_mouse_buf.count = 0;

    /* Flush the keyboard controller */
    while (hakios_inb(KBD_STATUS_PORT) & KBD_STATUS_OUTBUF)
        hakios_inb(KBD_DATA_PORT);

    /* Enable keyboard and mouse interrupts via the controller mode */
    kbd_write_command(KBD_CMD_READ_MODE);
    uint8_t mode = kbd_read_data();
    mode |= KBD_MODE_KBD_INT;        /* Enable keyboard interrupt */
    mode |= KBD_MODE_MOUSE_INT;     /* Enable mouse interrupt */
    mode &= ~KBD_MODE_KBD_DISABLE;  /* Enable keyboard */
    mode &= ~KBD_MODE_MOUSE_DISABLE; /* Enable mouse */
    kbd_write_command(KBD_CMD_WRITE_MODE);
    kbd_write_data(mode);

    /* Re-enable devices */
    kbd_write_command(KBD_CMD_ENABLE_KBD);
    kbd_write_command(KBD_CMD_ENABLE_MOUSE);

    hakios_serial_puts("HakiOS-x86: input initialized (i8042 PS/2)\n");
}

int
hakios_kbd_getc(void)
{
    /* Return next ASCII character, or 0 if none available */
    uint8_t sc = kbd_buf_pop();
    if (sc == 0)
        return 0;

    /* Check if this is a key press (bit 7 clear) */
    if (sc & 0x80)
        return 0;  /* Key release, ignore */

    return hakios_kbd_scancode_to_ascii(sc);
}

int
hakios_kbd_available(void)
{
    return hakios_kbd_buf.count > 0;
}

/* Mouse data format (PS/2 mouse, 3 bytes per packet) */
int
hakios_mouse_read(uint8_t *buf, int len)
{
    int count = 0;
    while (count < len && hakios_mouse_buf.count > 0) {
        buf[count] = hakios_mouse_buf.buf[hakios_mouse_buf.head];
        hakios_mouse_buf.head = (hakios_mouse_buf.head + 1) % MOUSE_BUF_SIZE;
        hakios_mouse_buf.count--;
        count++;
    }
    return count;
}

/* Register the interrupt handler */
void
hakios_input_register_irq(int irq)
{
    /*
     * Keyboard IRQ1 (0x01) and Mouse IRQ12 (0x0C) on the PIC/IOAPIC.
     * XNU's interrupt system will call hakios_kbd_interrupt when
     * these IRQs fire.
     *
     * The actual registration uses XNU's interrupt_register() or
     * PE_install_interrupt_handler().
     */
    /* TODO: Register hakios_kbd_interrupt for IRQ1 */
    /* TODO: Register mouse handler for IRQ12 */
}
