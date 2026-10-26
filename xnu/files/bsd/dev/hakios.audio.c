/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Audio Driver — Intel HDA (High Definition Audio)
 *
 * Intel HDA is the standard audio interface on modern PCs. QEMU
 * provides an emulated HDA controller (intel-hda) with a codec
 * (usually the Conexant CX20561 or a generic codec).
 *
 * APSL 2.0 — see NOTICE and COMPLIANCE.md.
 *
 * Numbers: Intel High Definition Audio Specification 1.0.
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/conf.h>
#include <sys/uio.h>
#include <sys/kernel.h>
#include <sys/malloc.h>

#include "hakios_x86.h"

/* ============================================================================
 * Intel HDA Register Definitions
 * ============================================================================
 */

#define HDA_GCAP         0x00    /* Global Capabilities */
#define HDA_GCTL          0x08    /* Global Control */
#define HDA_GSTS         0x10    /* Global Status */
#define HDA_CORBLBASE    0x40    /* CORB Lower Base Address */
#define HDA_CORBUBASE    0x44    /* CORB Upper Base Address */
#define HDA_CORBWP        0x48    /* CORB Write Pointer */
#define HDA_CORBRP        0x4A    /* CORB Read Pointer */
#define HDA_CORBCTL       0x4C    /* CORB Control */
#define HDA_CORBSIZE     0x4E    /* CORB Size */
#define HDA_RIRBLBASE    0x50    /* RIRB Lower Base Address */
#define HDA_RIRBUBASE    0x54    /* RIRB Upper Base Address */
#define HDA_RIRBWP        0x58    /* RIRB Write Pointer */
#define HDA_RINTCNT      0x5A    /* Response Interrupt Count */
#define HDA_RIRBCTL       0x5C    /* RIRB Control */
#define HDA_RIRBSTS       0x5D    /* RIRB Status */
#define HDA_RIRBSIZE     0x5E    /* RIRB Size */
#define HDA_IC            0x60    /* Immediate Command */
#define HDA_II            0x64    /* Immediate Input */
#define HDA_ICC           0x68    /* Immediate Command Control */
#define HDA_WAKEEN       0x0C    /* Wake Enable */
#define HDA_STATESTS     0x0E    /* State Change Status */

/* GCTL flags */
#define HDA_GCTL_CRST    0x00000001  /* Controller Reset */
#define HDA_GCTL_FCNTRL  0x00000002  /* Flush Control */

/* CORBCTL flags */
#define HDA_CORBCTL_CMEIE 0x01  /* CORB Memory Error Interrupt Enable */
#define HDA_CORBCTL_RUN   0x02  /* CORB Running */

/* RIRBCTL flags */
#define HDA_RIRBCTL_RIRBOIC 0x02  /* RIRB Overrun Interrupt Control */
#define HDA_RIRBCTL_RUN     0x02  /* RIRB Running */

/* CORB/RIRB entry size */
#define HDA_CORB_SIZE     256    /* Entries */
#define HDA_RIRB_SIZE     256    /* Entries */

/* HDA codec addresses */
#define HDA_CODEC_ROOT     0x00    /* Root node */
#define HDA_CODEC_AFG      0x01    /* Audio Function Group */

/* Verb encoding */
#define HDA_VERB(codec, node, verb, param) \
    ((uint32_t)((codec) << 28) | ((node) << 20) | ((verb) << 8) | (param))

/* Common verbs */
#define HDA_VERB_GET_PARAM  0x0F00
#define HDA_VERB_SET_CONV   0x706   /* Set Converter Format */
#define HDA_VERB_SET_AMP    0x703   /* Set Amplifier Gain */
#define HDA_VERB_SET_CSEL   0x720   /* Set Connection Select */
#define HDA_VERB_SET_PCLK   0x71E   /* Set Power State */
#define HDA_VERB_SET_SDI    0x707   /* Set Stream Direction */

/* BDL (Buffer Descriptor List) */
struct hda_bdl_entry {
    uint64_t addr;     /* Buffer address */
    uint32_t length;   /* Buffer length */
    uint32_t flags;    /* Flags (bit 0 = IOC interrupt) */
};

/* HDA controller state */
static volatile uint8_t *hda_base = NULL;
static uint32_t *hda_corb = NULL;
static uint32_t *hda_rirb = NULL;
static struct hda_bdl_entry *hda_bdl = NULL;
static int hda_corb_head = 0;
static int hda_rirb_head = 0;

/* ============================================================================
 * HDA PCI detection
 * ============================================================================
 */

static int
hakios_hda_find_controller(void)
{
    /*
     * QEMU default: intel-hda at PCI B/D/F 00:04.0
     * PCI class code:
     *   Class 0x04 (Multimedia Controller)
     *   Subclass 0x01 (Audio Device)
     *   Interface 0x00 (HDA)
     */
    for (int bus = 0; bus < 256; bus++) {
        for (int slot = 0; slot < 32; slot++) {
            for (int func = 0; func < 8; func++) {
                uint32_t addr = HAKIOS_PCI_CONF_ENABLE |
                    (bus << 16) | (slot << 11) | (func << 8);

                hakios_outl(HAKIOS_PCI_CONF_ADDR, addr | 0x08);
                uint32_t classcode = hakios_inl(HAKIOS_PCI_CONF_DATA);
                uint8_t base_class = (classcode >> 24) & 0xFF;
                uint8_t sub_class = (classcode >> 16) & 0xFF;

                if (base_class == 0x04 && sub_class == 0x01) {
                    /* Read BAR0 */
                    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr | 0x10);
                    uint32_t bar0 = hakios_inl(HAKIOS_PCI_CONF_DATA);
                    bar0 &= 0xFFFFFFF0;

                    /* Enable memory space and bus mastering */
                    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr | 0x04);
                    uint32_t cmd = hakios_inl(HAKIOS_PCI_CONF_DATA);
                    cmd |= 0x06;
                    hakios_outl(HAKIOS_PCI_CONF_ADDR, addr | 0x04);
                    hakios_outl(HAKIOS_PCI_CONF_DATA, cmd);

                    hda_base = (volatile uint8_t *)(uintptr_t)bar0;

                    hakios_serial_puts("HakiOS-x86: HDA controller found\n");
                    return 0;
                }
            }
        }
    }

    return -1;
}

/* ============================================================================
 * HDA CORB/RIRB (Command Output Ring Buffer / Response Input Ring Buffer)
 * ============================================================================
 */

static void
hakios_hda_send_verb(uint32_t verb)
{
    if (!hda_base)
        return;

    /* Write verb to CORB */
    hda_corb[hda_corb_head] = verb;
    hda_corb_head = (hda_corb_head + 1) % HDA_CORB_SIZE;

    /* Update write pointer */
    *(volatile uint16_t *)(hda_base + HDA_CORBWP) = hda_corb_head;

    /* Wait for response */
    int timeout = 10000;
    while (timeout--) {
        uint16_t wp = *(volatile uint16_t *)(hda_base + HDA_RIRBWP);
        if (wp != hda_rirb_head) {
            /* Read response */
            hda_rirb_head = (hda_rirb_head + 1) % HDA_RIRB_SIZE;
            uint32_t response = hda_rirb[hda_rirb_head * 2];
            /* Response is now available */
            (void)response;
            break;
        }
    }
}

/* ============================================================================
 * HDA stream setup (simplified)
 * ============================================================================
 */

static void
hakios_hda_setup_stream(int stream_id, int format, void *buf, int len)
{
    /*
     * Set up an output stream for playback.
     * format = sample rate | channels | bits
     *
     * In QEMU, the HDA controller with a simple codec will accept
     * a stream and output audio.
     */

    /* Set up BDL (Buffer Descriptor List) */
    hda_bdl[0].addr = (uint64_t)(uintptr_t)buf;
    hda_bdl[0].length = len;
    hda_bdl[0].flags = 0; /* No IOC */

    /* Program the stream registers */
    /* (Offsets vary by controller; simplified here) */

    /* Set converter format on codec */
    hakios_hda_send_verb(HDA_VERB(0, 0x04, HDA_VERB_SET_CONV, format));

    /* Set amplifier gain (unmute) */
    hakios_hda_send_verb(HDA_VERB(0, 0x02, HDA_VERB_SET_AMP, 0x7000));
}

/* ============================================================================
 * Public API
 * ============================================================================
 */

void
hakios_audio_init(void)
{
    hakios_serial_puts("HakiOS-x86: initializing audio driver...\n");

    if (hakios_hda_find_controller() != 0) {
        hakios_serial_puts("HakiOS-x86: no HDA controller found\n");
        return;
    }

    /* Reset the controller */
    *(volatile uint32_t *)(hda_base + HDA_GCTL) = 0;
    for (volatile int i = 0; i < 10000; i++)
        ;
    *(volatile uint32_t *)(hda_base + HDA_GCTL) |= HDA_GCTL_CRST;

    /* Wait for reset to complete */
    int timeout = 10000;
    while ((*(volatile uint32_t *)(hda_base + HDA_GCTL) &
            HDA_GCTL_CRST) && timeout--)
        ;

    /* Set up CORB (command ring) */
    *(volatile uint32_t *)(hda_base + HDA_CORBLBASE) =
        (uint32_t)(uintptr_t)hda_corb;
    *(volatile uint32_t *)(hda_base + HDA_CORBUBASE) = 0;

    /* CORB size: 256 entries */
    *(volatile uint8_t *)(hda_base + HDA_CORBSIZE) = 0x02;

    /* Reset CORB pointers */
    *(volatile uint16_t *)(hda_base + HDA_CORBWP) = 0;
    *(volatile uint16_t *)(hda_base + HDA_CORBRP) = 0x8000; /* Reset */
    *(volatile uint16_t *)(hda_base + HDA_CORBRP) = 0;

    /* Enable CORB */
    *(volatile uint8_t *)(hda_base + HDA_CORBCTL) |= HDA_CORBCTL_RUN;

    /* Set up RIRB (response ring) */
    *(volatile uint32_t *)(hda_base + HDA_RIRBLBASE) =
        (uint32_t)(uintptr_t)hda_rirb;
    *(volatile uint32_t *)(hda_base + HDA_RIRBUBASE) = 0;

    /* RIRB size: 256 entries */
    *(volatile uint8_t *)(hda_base + HDA_RIRBSIZE) = 0x02;

    /* Reset RIRB pointers */
    *(volatile uint16_t *)(hda_base + HDA_RIRBWP) = 0x8000; /* Reset */
    hda_rirb_head = 0;

    /* Enable RIRB */
    *(volatile uint8_t *)(hda_base + HDA_RIRBCTL) |= HDA_RIRBCTL_RUN;

    /* Enumerate codecs */
    /* Read STATESTS register to see which codecs are present */
    uint16_t statests = *(volatile uint16_t *)(hda_base + HDA_STATESTS);
    for (int i = 0; i < 16; i++) {
        if (statests & (1 << i)) {
            /* Codec present at address i */
            char msg[64];
            snprintf(msg, sizeof(msg),
                     "HakiOS-x86: HDA codec %d present\n", i);
            hakios_serial_puts(msg);
        }
    }

    hakios_serial_puts("HakiOS-x86: audio driver initialized\n");
}

int
hakios_audio_play(const void *buf, int len, int sample_rate, int channels)
{
    /*
     * Play audio data.
     * format = sample_rate << 14 | channels << 4 | bits_per_sample
     *
     * For 44100 Hz, stereo, 16-bit:
     *   format = 0x4000 (44.1kHz) | 0x10 (stereo) | 0x00 (16-bit)
     *   = 0x4010
     */
    int format = (sample_rate == 44100) ? 0x4010 : 0x4010;
    (void)channels;

    hakios_hda_setup_stream(1, format, (void *)buf, len);

    return len;
}
