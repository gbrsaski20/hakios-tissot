#!/usr/bin/env python3
"""
make_tissot_bootimg.py — Pack an Android boot image for Xiaomi Mi A1 (tissot).

Produces a REAL, structurally valid Android boot image that `fastboot` and the
Qualcomm ABL bootloader will accept:

    fastboot boot prebuilt/tissot-boot.img          # try without flashing
    fastboot flash boot prebuilt/tissot-boot.img    # permanent

Format
------
Android boot image, header version 0 (the format every 2017 Qualcomm device
understands), page size 2048:

    page 0            header (1632 bytes) + zero padding to 2048
    page 1..N         kernel      (aarch64 Image)
    page N+1..M       ramdisk     (gzip'ed cpio "newc" archive)
    (second stage     omitted, second_size = 0)
    page M+1..K       dtb         (appended device tree, Qualcomm style)

The 32-byte `id` field holds the SHA-1 of kernel+ramdisk+second+dtb so the
image is self-verifying.

Also generates a minimal but *valid* ramdisk (gzipped cpio newc archive with
an /init script) so the bootloader has something real to unpack.

Usage
-----
    python tools/make_tissot_bootimg.py
    python tools/make_tissot_bootimg.py --kernel X --dtb Y --ramdisk Z --out W
    python tools/make_tissot_bootimg.py --no-ramdisk
"""

import argparse
import gzip
import hashlib
import io
import os
import struct
import sys
import zlib

BOOT_MAGIC = b"ANDROID!"
PAGE_SIZE = 2048
HEADER_SIZE = 1632  # v0 header is exactly 1632 bytes

# Qualcomm msm8953 memory layout (base 0x80000000)
BASE = 0x80000000
KERNEL_ADDR = BASE + 0x00008000   # 0x80008000
RAMDISK_ADDR = BASE + 0x01000000  # 0x81000000
SECOND_ADDR = BASE + 0x00F00000   # 0x80f00000
TAGS_ADDR = BASE + 0x00000100     # 0x80000100

BOOT_NAME = "hakios-tissot"
# Stock tissot cmdline (LineageOS android_device_xiaomi_tissot, cm-14.1 BoardConfig.mk)
BOOT_CMDLINE = (
    "androidboot.console=ttyHSL0 "
    "androidboot.hardware=qcom "
    "msm_rtb.filter=0x237 "
    "ehci-hcd.park=3 "
    "lpm_levels.sleep_disabled=1 "
    "androidboot.bootdevice=7824900.sdhci "
    "earlycon=msm_hsl_uart,0x78af000 "
    "androidboot.selinux=permissive"
)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def pad_to(data, page=PAGE_SIZE):
    """Zero-pad to a multiple of `page` (returns unchanged if already aligned)."""
    rem = len(data) % page
    return data if rem == 0 else data + b"\x00" * (page - rem)


def pages_for(n, page=PAGE_SIZE):
    return (n + page - 1) // page


def encode_os_version(major, minor, patch, year, month):
    """Android os_version encoding: A.B.C with YYYY-MM."""
    return (((major & 0x7F) << 25) |
            ((minor & 0x7F) << 18) |
            ((patch & 0x7F) << 11) |
            (((year - 2000) & 0x7F) << 4) |
            (month & 0x0F))


# ---------------------------------------------------------------------------
# minimal but valid ramdisk: gzip'ed cpio "newc"
# ---------------------------------------------------------------------------
INIT_SCRIPT = b"""#!/system/bin/sh
# HakiOS / tissot ramdisk init (placeholder)
#
# This ramdisk exists so the boot image is structurally complete.
# When booting a real XNU kernel this is replaced by the iOS root
# (sysimage/ios16-root.simg, see docs/PORT-TISSOT.md 4.2).
echo "hakios: tissot ramdisk init reached"
exec /bin/sh
"""


def _cpio_entry(name, data, mode, ino):
    """One cpio 'newc' (SVR4, no CRC) entry."""
    namez = name.encode("ascii") + b"\x00"
    fields = [
        ino, mode, 0, 0, 1, 0, len(data),
        0, 0, 0, 0, len(namez), 0,
    ]
    hdr = b"070701" + b"".join(b"%08X" % f for f in fields)
    assert len(hdr) == 110, len(hdr)
    out = hdr + namez
    out += b"\x00" * ((4 - len(out) % 4) % 4)
    out += data
    out += b"\x00" * ((4 - len(data) % 4) % 4)
    return out


def build_ramdisk():
    """Return gzip-compressed cpio newc archive bytes."""
    S_IFREG = 0o100000
    S_IFDIR = 0o040000

    cpio = bytearray()
    cpio += _cpio_entry(".", b"", S_IFDIR | 0o755, 1)
    cpio += _cpio_entry("init", INIT_SCRIPT, S_IFREG | 0o755, 2)
    cpio += _cpio_entry("TRAILER!!!", b"", 0, 0)
    # pad archive to 512 bytes
    cpio += b"\x00" * ((512 - len(cpio) % 512) % 512)

    buf = io.BytesIO()
    # mtime=0 -> deterministic output
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(bytes(cpio))
    return buf.getvalue()


# ---------------------------------------------------------------------------
# boot image header (v0)
# ---------------------------------------------------------------------------
def build_header(kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
                 second_size, second_addr, tags_addr, page_size,
                 header_version, os_version, name, cmdline, sha1_id,
                 extra_cmdline=b""):
    h = bytearray()
    h += BOOT_MAGIC
    h += struct.pack(
        "<10I",
        kernel_size, kernel_addr,
        ramdisk_size, ramdisk_addr,
        second_size, second_addr,
        tags_addr, page_size,
        header_version, os_version,
    )
    h += name.encode("ascii")[:16].ljust(16, b"\x00")
    h += cmdline.encode("ascii")[:512].ljust(512, b"\x00")
    h += sha1_id[:32].ljust(32, b"\x00")
    h += extra_cmdline[:1024].ljust(1024, b"\x00")

    if len(h) != HEADER_SIZE:
        raise AssertionError(f"header is {len(h)} bytes, expected {HEADER_SIZE}")
    return bytes(h)


# ---------------------------------------------------------------------------
# pack
# ---------------------------------------------------------------------------
def pack_bootimg(kernel, ramdisk, dtb, second=b"",
                 page_size=PAGE_SIZE, header_version=0,
                 kernel_addr=KERNEL_ADDR, ramdisk_addr=RAMDISK_ADDR,
                 second_addr=SECOND_ADDR, tags_addr=TAGS_ADDR,
                 name=BOOT_NAME, cmdline=BOOT_CMDLINE,
                 os_version=None, kernel_format="gz-dtb"):
    """Pack an Android boot image.

    kernel_format:
      "gz-dtb" — gzip the raw arm64 Image and append the DTB, producing the
                 `Image.gz-dtb` payload that tissot's stock boot image uses
                 (BOARD_KERNEL_IMAGE_NAME := Image.gz-dtb). No separate dtb
                 section is written in this mode.
      "raw"    — store the Image as-is and put the DTB in its own section.
    """
    if os_version is None:
        os_version = encode_os_version(9, 0, 0, 2019, 1)  # Android 9.0.0, 2019-01

    if kernel_format == "gz-dtb":
        kernel_payload = gzip.compress(kernel, compresslevel=9, mtime=0) + dtb
        dtb_section = b""
        kernel_label = "kernel[gz+dtb]"
    elif kernel_format == "raw":
        kernel_payload = kernel
        dtb_section = dtb
        kernel_label = "kernel"
    else:
        raise ValueError(f"unknown kernel_format: {kernel_format!r}")

    sha1 = hashlib.sha1()
    sha1.update(kernel_payload)
    sha1.update(ramdisk)
    sha1.update(second)
    sha1.update(dtb_section)
    sha1_id = sha1.digest()

    hdr = build_header(
        kernel_size=len(kernel_payload), kernel_addr=kernel_addr,
        ramdisk_size=len(ramdisk), ramdisk_addr=ramdisk_addr,
        second_size=len(second), second_addr=second_addr,
        tags_addr=tags_addr, page_size=page_size,
        header_version=header_version, os_version=os_version,
        name=name, cmdline=cmdline, sha1_id=sha1_id,
    )

    parts = [
        ("header", pad_to(hdr, page_size)),
        (kernel_label, pad_to(kernel_payload, page_size)),
        ("ramdisk", pad_to(ramdisk, page_size)),
    ]
    if second:
        parts.append(("second", pad_to(second, page_size)))
    if dtb_section:
        parts.append(("dtb", pad_to(dtb_section, page_size)))

    img = bytearray()
    layout = []
    for label, chunk in parts:
        layout.append((label, len(img), len(chunk)))
        img += chunk

    return bytes(img), layout, sha1_id


# ---------------------------------------------------------------------------
# verify: re-parse the produced image
# ---------------------------------------------------------------------------
def verify_bootimg(data, page_size=PAGE_SIZE):
    msgs = []
    ok = True

    if len(data) < HEADER_SIZE:
        return False, ["image smaller than header"]

    if data[:8] != BOOT_MAGIC:
        return False, [f"BAD magic {data[:8]!r} (expected b'ANDROID!')"]
    msgs.append(f"magic           = {data[:8].decode()!r}  (OK)")

    (kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
     second_size, second_addr, tags_addr, hdr_page_size,
     header_version, os_version) = struct.unpack("<10I", data[8:48])

    name = data[48:64].rstrip(b"\x00").decode("ascii", "replace")
    cmdline = data[64:576].rstrip(b"\x00").decode("ascii", "replace")
    stored_id = data[576:608]
    extra = data[608:1632].rstrip(b"\x00").decode("ascii", "replace")

    msgs.append(f"kernel_size     = {kernel_size}  @ 0x{kernel_addr:08x}")
    msgs.append(f"ramdisk_size    = {ramdisk_size}  @ 0x{ramdisk_addr:08x}")
    msgs.append(f"second_size     = {second_size}  @ 0x{second_addr:08x}")
    msgs.append(f"tags_addr       = 0x{tags_addr:08x}")
    msgs.append(f"page_size       = {hdr_page_size}")
    msgs.append(f"header_version  = {header_version}")
    msgs.append(f"os_version      = 0x{os_version:08x}")
    msgs.append(f"name            = {name!r}")
    msgs.append(f"cmdline         = {cmdline!r}")
    if extra:
        msgs.append(f"extra_cmdline   = {extra!r}")

    if hdr_page_size != page_size:
        ok = False
        msgs.append(f"BAD page_size {hdr_page_size} != {page_size}")

    # Recompute offsets: header page, then kernel, ramdisk, second, dtb
    off = hdr_page_size
    k_off = off
    off += pages_for(kernel_size, hdr_page_size) * hdr_page_size
    r_off = off
    off += pages_for(ramdisk_size, hdr_page_size) * hdr_page_size
    s_off = off
    off += pages_for(second_size, hdr_page_size) * hdr_page_size
    d_off = off

    # ---- extract payloads ----
    kernel_stored = data[k_off:k_off + kernel_size]
    ramdisk = data[r_off:r_off + ramdisk_size]
    second = data[s_off:s_off + second_size]

    # ---- kernel may be `Image.gz-dtb` = gzip(Image) + appended DTB ----
    appended_dtb = b""
    if kernel_stored[:2] == b"\x1f\x8b":
        kernel_kind = "Image.gz-dtb"
        try:
            dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
            raw_img = dec.decompress(kernel_stored) + dec.flush()
            appended_dtb = dec.unused_data
        except Exception as e:
            ok = False
            raw_img = b""
            kernel_kind = f"gzip ERROR ({e})"
    else:
        kernel_kind = "raw Image"
        raw_img = kernel_stored

    # ---- locate the DTB ----
    if appended_dtb:
        dtb = appended_dtb
        dtb_section = b""
        dtb_size = len(dtb)
        dtb_src = "appended to kernel"
    else:
        dtb_region = data[d_off:]
        if (len(dtb_region) >= 40 and
                struct.unpack(">I", dtb_region[:4])[0] == 0xD00DFEED):
            dtb_size = struct.unpack(">I", dtb_region[4:8])[0]
            if dtb_size > len(dtb_region):
                ok = False
                msgs.append(f"BAD dtb totalsize {dtb_size} > region {len(dtb_region)}")
                dtb_size = len(dtb_region)
        else:
            dtb_size = len(dtb_region)
        dtb = data[d_off:d_off + dtb_size]
        dtb_section = dtb
        dtb_src = "separate boot.img section"

    msgs.append("")
    msgs.append("page map (recomputed from header):")
    msgs.append(f"  header   @ 0x{k_off - hdr_page_size:06x}  "
                f"{hdr_page_size} bytes (1 page)")
    msgs.append(f"  kernel   @ 0x{k_off:06x}  {kernel_size} bytes "
                f"({pages_for(kernel_size)} page(s))  [{kernel_kind}]")
    msgs.append(f"  ramdisk  @ 0x{r_off:06x}  {ramdisk_size} bytes "
                f"({pages_for(ramdisk_size)} page(s))")
    if second_size:
        msgs.append(f"  second   @ 0x{s_off:06x}  {second_size} bytes")
    msgs.append(f"  dtb      @ 0x{d_off:06x}  {dtb_size} bytes  ({dtb_src})")

    # Verify SHA-1 over the bytes exactly as stored
    sha1 = hashlib.sha1()
    sha1.update(kernel_stored)
    sha1.update(ramdisk)
    sha1.update(second)
    sha1.update(dtb_section)
    calc = sha1.digest()
    if calc != stored_id[:20]:
        ok = False
        msgs.append("")
        msgs.append(f"BAD id: stored {stored_id[:20].hex()} != "
                    f"computed {calc.hex()}")
    else:
        msgs.append("")
        msgs.append(f"sha1 id         = {calc.hex()}  (matches stored)")

    # Verify the kernel (decompressed if it was gz) is a valid arm64 Image
    msgs.append("")
    if len(raw_img) >= 64 and struct.unpack("<I", raw_img[56:60])[0] == 0x644D5241:
        msgs.append(f"kernel check    = arm64 Image magic 'ARM\\x64' OK "
                    f"({kernel_kind}, {len(raw_img)} bytes)")
    else:
        ok = False
        msgs.append(f"kernel check    = BAD (missing ARM\\x64 magic) [{kernel_kind}]")

    # Verify embedded dtb is a valid FDT
    if len(dtb) >= 40 and struct.unpack(">I", dtb[:4])[0] == 0xD00DFEED:
        (tot,) = struct.unpack(">I", dtb[4:8])
        msgs.append(f"dtb check       = FDT magic OK, totalsize={tot} "
                    f"({'matches' if tot == len(dtb) else 'MISMATCH'})")
        if tot != len(dtb):
            ok = False
    else:
        ok = False
        msgs.append("dtb check       = BAD (missing FDT magic 0xd00dfeed)")

    # Verify ramdisk is gzip
    if ramdisk[:2] == b"\x1f\x8b":
        msgs.append("ramdisk check   = gzip magic 1f 8b OK")
    else:
        msgs.append("ramdisk check   = not gzip (acceptable if empty)")
        if ramdisk_size:
            ok = False

    return ok, msgs


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main(argv=None):
    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)
    prebuilt = os.path.join(root_dir, "prebuilt")

    ap = argparse.ArgumentParser(
        description="Pack an Android boot image for Xiaomi Mi A1 (tissot)")
    ap.add_argument("--kernel", default=os.path.join(prebuilt,
                                                     "tissot-kernel-arm64.Image"))
    ap.add_argument("--dtb", default=os.path.join(prebuilt, "tissot.dtb"))
    ap.add_argument("--ramdisk", default=None,
                    help="ramdisk file (default: generate a minimal cpio.gz)")
    ap.add_argument("--out", default=os.path.join(prebuilt, "tissot-boot.img"))
    ap.add_argument("--no-ramdisk", action="store_true",
                    help="build with an empty ramdisk")
    ap.add_argument("--page-size", type=int, default=PAGE_SIZE)
    ap.add_argument("--kernel-format", choices=("gz-dtb", "raw"), default="gz-dtb",
                    help="kernel payload layout (default: gz-dtb = Image.gz + "
                         "appended DTB, matching stock tissot boot.img)")
    args = ap.parse_args(argv)

    print("=" * 62)
    print("  Mi A1 (tissot) Android boot image packer")
    print("=" * 62)
    print()

    # ---- inputs ----
    missing = []
    for label, path in (("kernel", args.kernel), ("dtb", args.dtb)):
        if not os.path.isfile(path):
            missing.append((label, path))
    if missing:
        print("  ERROR: required input(s) missing:")
        for label, path in missing:
            print(f"    {label}: {path}")
        print()
        print("  Build them first:")
        print("    python tools/build_kernel_placeholder_arm64.py")
        print("    python tools/build_tissot_dtb.py")
        return 1

    with open(args.kernel, "rb") as f:
        kernel = f.read()
    with open(args.dtb, "rb") as f:
        dtb = f.read()

    # ---- ramdisk ----
    if args.no_ramdisk:
        ramdisk = b""
        print("  ramdisk: (none — empty)")
    elif args.ramdisk:
        with open(args.ramdisk, "rb") as f:
            ramdisk = f.read()
        print(f"  ramdisk: {os.path.relpath(args.ramdisk, root_dir)} "
              f"({len(ramdisk)} bytes)")
    else:
        ramdisk = build_ramdisk()
        rd_path = os.path.join(prebuilt, "tissot-ramdisk.cpio.gz")
        with open(rd_path, "wb") as f:
            f.write(ramdisk)
        print(f"  ramdisk: generated {os.path.relpath(rd_path, root_dir)} "
              f"({len(ramdisk)} bytes)")

    print(f"  kernel : {os.path.relpath(args.kernel, root_dir)} "
          f"({len(kernel)} bytes)")
    print(f"  dtb    : {os.path.relpath(args.dtb, root_dir)} ({len(dtb)} bytes)")
    print()

    # ---- pack ----
    img, layout, sha1_id = pack_bootimg(
        kernel, ramdisk, dtb, page_size=args.page_size,
        kernel_format=args.kernel_format)

    # ---- verify ----
    ok, msgs = verify_bootimg(img, page_size=args.page_size)
    print("  Verification (re-parse of packed image):")
    for m in msgs:
        print(f"    {m}" if m else "")
    print()

    if not ok:
        print("  ERROR: packed image failed verification. Not writing.")
        return 1

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(img)

    print(f"  Wrote: {os.path.relpath(args.out, root_dir)}  "
          f"({len(img)} bytes, {pages_for(len(img), args.page_size)} pages)")
    print()
    print("  Next steps (Mi A1 must have an UNLOCKED bootloader):")
    print("    fastboot devices")
    print(f"    fastboot boot  {os.path.relpath(args.out, root_dir)}")
    print("      -> try without flashing; if it boots, make it permanent:")
    print(f"    fastboot flash boot {os.path.relpath(args.out, root_dir)}")
    print()
    print("  NOTE: the kernel inside is a PLACEHOLDER (wfi spin loop).")
    print("  A real XNU ARM64 kernel needs cctools + macOS SDK, and the")
    print("  MSM8953 (ARMv8.0) vs iOS 16 (ARMv8.2) risk in")
    print("  docs/PORT-TISSOT.md section 6 still applies.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
