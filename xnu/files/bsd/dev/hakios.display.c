/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Display Driver — VGA text mode + Bochs VBE graphics
 *
 * This driver provides a framebuffer interface for the XNU kernel
 * on x86_64. It supports two modes:
 *
 *   1. VGA text mode (80x25, 16 colors) — default, for early boot
 *   2. Bochs VBE (VESA BIOS Extensions) — for graphics, via the
 *      QEMU/Bochs dispi interface at I/O ports 0x01CE/0x01CF
 *
 * APSL 2.0 — see NOTICE and COMPLIANCE.md.
 *
 * Numbers: These are standard PC I/O ports documented in the
 * PCI/ISA specifications and the Bochs/QEMU documentation.
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/conf.h>
#include <sys/uio.h>
#include <sys/kernel.h>
#include <sys/malloc.h>

#include "hakios_x86.h"

/* Current display mode */
static int hakios_display_mode = 0;  /* 0 = text, 1 = VBE graphics */
static int hakios_display_width = HAKIOS_VGA_TEXT_WIDTH;
static int hakios_display_height = HAKIOS_VGA_TEXT_HEIGHT;
static int hakios_display_depth = 16;

/* Text mode cursor position */
static int hakios_cursor_x = 0;
static int hakios_cursor_y = 0;

/* VGA text mode attribute (white on black) */
#define HAKIOS_VGA_ATTR 0x0F

/* VBE framebuffer (set when graphics mode is enabled) */
static volatile uint32_t *hakios_vbe_fb = NULL;
static int hakios_vbe_pitch = 0;

/* ============================================================================
 * VGA text mode
 * ============================================================================
 */

static void
hakios_vga_text_putc(char c)
{
    volatile uint16_t *vga = (volatile uint16_t *)HAKIOS_VGA_TEXT_BASE;

    if (c == '\n') {
        hakios_cursor_x = 0;
        hakios_cursor_y++;
        if (hakios_cursor_y >= HAKIOS_VGA_TEXT_HEIGHT) {
            /* Scroll up */
            for (int i = 0; i < (HAKIOS_VGA_TEXT_HEIGHT - 1) * HAKIOS_VGA_TEXT_WIDTH; i++) {
                vga[i] = vga[i + HAKIOS_VGA_TEXT_WIDTH];
            }
            /* Clear last line */
            for (int i = 0; i < HAKIOS_VGA_TEXT_WIDTH; i++) {
                vga[(HAKIOS_VGA_TEXT_HEIGHT - 1) * HAKIOS_VGA_TEXT_WIDTH + i] =
                    (HAKIOS_VGA_ATTR << 8) | ' ';
            }
            hakios_cursor_y = HAKIOS_VGA_TEXT_HEIGHT - 1;
        }
        return;
    }

    if (c == '\r') {
        hakios_cursor_x = 0;
        return;
    }

    if (c == '\t') {
        hakios_cursor_x = (hakios_cursor_x + 8) & ~7;
        if (hakios_cursor_x >= HAKIOS_VGA_TEXT_WIDTH) {
            hakios_cursor_x = 0;
            hakios_cursor_y++;
        }
        return;
    }

    /* Write character */
    vga[hakios_cursor_y * HAKIOS_VGA_TEXT_WIDTH + hakios_cursor_x] =
        (HAKIOS_VGA_ATTR << 8) | c;
    hakios_cursor_x++;

    if (hakios_cursor_x >= HAKIOS_VGA_TEXT_WIDTH) {
        hakios_cursor_x = 0;
        hakios_cursor_y++;
        if (hakios_cursor_y >= HAKIOS_VGA_TEXT_HEIGHT) {
            /* Scroll up (same as above) */
            for (int i = 0; i < (HAKIOS_VGA_TEXT_HEIGHT - 1) * HAKIOS_VGA_TEXT_WIDTH; i++) {
                vga[i] = vga[i + HAKIOS_VGA_TEXT_WIDTH];
            }
            for (int i = 0; i < HAKIOS_VGA_TEXT_WIDTH; i++) {
                vga[(HAKIOS_VGA_TEXT_HEIGHT - 1) * HAKIOS_VGA_TEXT_WIDTH + i] =
                    (HAKIOS_VGA_ATTR << 8) | ' ';
            }
            hakios_cursor_y = HAKIOS_VGA_TEXT_HEIGHT - 1;
        }
    }
}

static void
hakios_vga_text_update_cursor(void)
{
    uint16_t pos = hakios_cursor_y * HAKIOS_VGA_TEXT_WIDTH + hakios_cursor_x;
    hakios_outb(0x3D4, 0x0F);
    hakios_outb(0x3D5, pos & 0xFF);
    hakios_outb(0x3D4, 0x0E);
    hakios_outb(0x3D5, (pos >> 8) & 0xFF);
}

static void
hakios_vga_text_clear(void)
{
    volatile uint16_t *vga = (volatile uint16_t *)HAKIOS_VGA_TEXT_BASE;
    uint16_t blank = (HAKIOS_VGA_ATTR << 8) | ' ';
    for (int i = 0; i < HAKIOS_VGA_TEXT_WIDTH * HAKIOS_VGA_TEXT_HEIGHT; i++) {
        vga[i] = blank;
    }
    hakios_cursor_x = 0;
    hakios_cursor_y = 0;
}

/* ============================================================================
 * Bochs VBE (VESA) graphics mode
 * ============================================================================
 */

static void
hakios_vbe_write(uint16_t reg, uint16_t val)
{
    hakios_outw(HAKIOS_VBE_DISPI_IOPORT, reg);
    hakios_outw(HAKIOS_VBE_DISPI_DATA, val);
}

static uint16_t
hakios_vbe_read(uint16_t reg)
{
    hakios_outw(HAKIOS_VBE_DISPI_IOPORT, reg);
    return hakios_inw(HAKIOS_VBE_DISPI_DATA);
}

static void
hakios_vbe_set_mode(int width, int height, int bpp)
{
    /* Disable VBE */
    hakios_vbe_write(HAKIOS_VBE_DISPI_ENABLE, 0x00);

    /* Set X resolution */
    hakios_vbe_write(HAKIOS_VBE_DISPI_XRES, width);
    /* Set Y resolution */
    hakios_vbe_write(HAKIOS_VBE_DISPI_YRES, height);
    /* Set bits per pixel */
    hakios_vbe_write(HAKIOS_VBE_DISPI_BPP, bpp);
    /* Enable VBE with linear framebuffer */
    hakios_vbe_write(HAKIOS_VBE_DISPI_ENABLE,
                     HAKIOS_VBE_DISPI_LFB | 0x01);

    hakios_vbe_fb = (volatile uint32_t *)HAKIOS_VGA_VBE_BASE;
    hakios_vbe_pitch = width;
    hakios_display_mode = 1;
    hakios_display_width = width;
    hakios_display_height = height;
    hakios_display_depth = bpp;
}

static void
hakios_vbe_putpixel(int x, int y, uint32_t color)
{
    if (!hakios_vbe_fb)
        return;
    if (x < 0 || x >= hakios_display_width ||
        y < 0 || y >= hakios_display_height)
        return;
    hakios_vbe_fb[y * hakios_vbe_pitch + x] = color;
}

/* ============================================================================
 * Public API
 * ============================================================================
 */

void
hakios_display_init(void)
{
    /* Start with VGA text mode */
    hakios_vga_text_clear();
    hakios_vga_text_update_cursor();

    /* Try to set VBE mode for graphics */
    /* Check if VBE is available */
    uint16_t id = hakios_vbe_read(0x00);
    if (id == 0xB0C0 || id == 0xB0C1 || id == 0xB0C2) {
        /* VBE is available, enable graphics mode */
        hakios_vbe_set_mode(HAKIOS_VGA_VBE_WIDTH,
                            HAKIOS_VGA_VBE_HEIGHT,
                            HAKIOS_VGA_VBE_DEPTH);

        /* Fill with black */
        for (int y = 0; y < hakios_display_height; y++) {
            for (int x = 0; x < hakios_display_width; x++) {
                hakios_vbe_putpixel(x, y, 0x00000000);
            }
        }
    }

    hakios_serial_puts("HakiOS-x86: display initialized\n");
}

void
hakios_display_putc(char c)
{
    if (hakios_display_mode == 0) {
        /* Text mode */
        hakios_vga_text_putc(c);
        hakios_vga_text_update_cursor();
    } else {
        /* Graphics mode: we still write to text mode for simplicity */
        /* A full implementation would render a font here */
        hakios_vga_text_putc(c);
        hakios_vga_text_update_cursor();
    }
}

void
hakios_display_puts(const char *str)
{
    while (*str) {
        hakios_display_putc(*str);
        str++;
    }
}

int
hakios_display_get_width(void)
{
    return hakios_display_width;
}

int
hakios_display_get_height(void)
{
    return hakios_display_height;
}

int
hakios_display_get_depth(void)
{
    return hakios_display_depth;
}

void *
hakios_display_get_framebuffer(void)
{
    if (hakios_display_mode == 1) {
        return (void *)hakios_vbe_fb;
    }
    return (void *)HAKIOS_VGA_TEXT_BASE;
}
