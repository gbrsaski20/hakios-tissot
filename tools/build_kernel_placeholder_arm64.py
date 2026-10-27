#!/usr/bin/env python3
"""
build_kernel_placeholder_arm64.py — Build a placeholder ARM64 kernel image
for Xiaomi Mi A1 (tissot), in the AArch64 Linux/Android `Image` format.

Why this format
---------------
ARM64 bootloaders (Qualcomm ABL on msm8953) do NOT boot an ELF. They boot the
raw `Image` format: a 64-byte header followed by position-independent code.
The header must carry the magic 0x644d5241 ("ARM\\x64") at offset 56, otherwise
the bootloader refuses the image.

Header layout (Documentation/arm64/booting.rst):
    offset  size  field
    0x00    4     code0        (branch instruction, usually `b` past header)
    0x04    4     code1        (branch or 0)
    0x08    8     text_offset  (load offset from RAM base)
    0x10    8     image_size   (total image size, multiple of 8)
    0x18    8     flags        bit1..2 page size, bit3 placement
    0x20    8     res2
    0x28    8     res3
    0x30    8     res4
    0x38    4     magic        0x644d5241 = "ARM\\x64"
    0x3c    4     res5

What this produces
------------------
A structurally valid `Image` whose entry point spins in a low-power loop and
prints nothing (no UART driver yet). It exists so the whole build -> pack ->
fastboot pipeline can be exercised end to end, exactly like the x86 path uses
tools/build_kernel_placeholder.py.

Replace it with a real XNU ARM64 kernel once you can build one:
    prebuilt/tissot-kernel-arm64.Image

Usage
-----
    python tools/build_kernel_placeholder_arm64.py
    python tools/build_kernel_placeholder_arm64.py --size 131072
"""

import argparse
import os
import struct
import sys

ARM64_IMAGE_MAGIC = 0x644D5241  # bytes: 41 52 4d 64 -> "ARM\x64"

# AArch64 instruction encodings
INS_B_SELF = 0x14000000      # b .        (branch to self, infinite loop)
INS_WFI = 0xD503207F         # wfi        (wait for interrupt, low power)

HEADER_SIZE = 64
DEFAULT_SIZE = 64 * 1024     # 64 KiB — plausible minimal kernel


def build_image(total_size=DEFAULT_SIZE):
    """Return a valid AArch64 Image of exactly total_size bytes."""

    if total_size < HEADER_SIZE + 16:
        raise ValueError("image too small")
    # image_size must be a multiple of 8 (arm64 requirement)
    total_size = (total_size + 7) & ~7

    # code0: branch from offset 0 to offset 64 (jump over the header).
    # `b` imm26: target = PC + imm26*4  ->  64 = 0 + 16*4  -> imm26 = 16
    code0 = INS_B_SELF | 16
    code1 = 0

    text_offset = 0x80000   # 512 KiB — conventional arm64 load offset
    flags = (1 << 1) | (1 << 3)  # bit1: 4K pages, bit3: 2MiB-aligned placement

    header = struct.pack(
        "<IIQQQQQQII",
        code0,          # code0
        code1,          # code1
        text_offset,    # text_offset
        total_size,     # image_size (patched here, correct value)
        flags,          # flags
        0,              # res2
        0,              # res3
        0,              # res4
        ARM64_IMAGE_MAGIC,
        0,              # res5
    )
    assert len(header) == HEADER_SIZE, len(header)

    # --- payload starting at offset 64: spin loop + banner ---
    body = bytearray()
    body += struct.pack("<I", INS_WFI)      # wfi
    body += struct.pack("<I", INS_B_SELF)   # b .   (spin)

    banner = (
        "\n"
        "  ================================================\n"
        "   HakiOS / tissot  -  ARM64 placeholder kernel\n"
        "  ================================================\n"
        "   Device : Xiaomi Mi A1 (tissot)\n"
        "   SoC    : Qualcomm MSM8953 / Snapdragon 625\n"
        "   CPU    : 8x Cortex-A53 (ARMv8.0-A)\n"
        "   Format : AArch64 Image (magic ARM\\x64)\n"
        "\n"
        "   [PLACEHOLDER KERNEL]\n"
        "   The CPU reached the kernel entry point and is now\n"
        "   spinning in a wfi loop. No drivers are initialised.\n"
        "\n"
        "   A real XNU ARM64 kernel requires cctools + macOS SDK.\n"
        "   Replace this file with the real build output:\n"
        "     prebuilt/tissot-kernel-arm64.Image\n"
        "\n"
        "   See docs/PORT-TISSOT.md for the full port plan.\n"
        "\n"
    ).encode("ascii")
    body += banner
    body += b"\x00"

    image = bytearray(header) + body
    if len(image) > total_size:
        raise ValueError(
            f"payload {len(image)} exceeds requested size {total_size}")
    image += b"\x00" * (total_size - len(image))
    return bytes(image)


def verify_image(data):
    """Parse the Image header back and validate."""
    msgs = []
    ok = True
    if len(data) < HEADER_SIZE:
        return False, ["file shorter than 64-byte header"]

    (code0, code1, text_offset, image_size, flags,
     res2, res3, res4, magic, res5) = struct.unpack("<IIQQQQQQII", data[:64])

    if magic != ARM64_IMAGE_MAGIC:
        ok = False
        msgs.append(f"BAD magic 0x{magic:08x} (expected 0x644d5241 'ARM\\x64')")
    else:
        magic_bytes = struct.pack("<I", magic)
        msgs.append(f"magic           = 0x{magic:08x}  "
                    f"({magic_bytes.decode('ascii', 'replace')!r}, OK)")

    if image_size != len(data):
        ok = False
        msgs.append(f"BAD image_size {image_size} != file size {len(data)}")
    else:
        msgs.append(f"image_size      = {image_size} bytes (matches file)")

    if image_size % 8:
        ok = False
        msgs.append("BAD image_size not a multiple of 8")

    if (code0 & 0xFC000000) != 0x14000000:
        ok = False
        msgs.append(f"BAD code0 0x{code0:08x} is not a `b` instruction")
    else:
        imm26 = code0 & 0x03FFFFFF
        target = imm26 * 4
        msgs.append(f"code0           = 0x{code0:08x}  (`b` +{target} bytes)")

    msgs.append(f"text_offset     = 0x{text_offset:x}")
    msgs.append(f"flags           = 0x{flags:x}  "
                f"(4K pages={'yes' if flags & 0x6 == 0x2 else 'no'})")

    # Check the spin loop lands where code0 branches to
    entry = 64
    if entry + 8 <= len(data):
        ins1, ins2 = struct.unpack("<II", data[entry:entry + 8])
        if ins1 != INS_WFI:
            ok = False
            msgs.append(f"BAD instruction at entry: 0x{ins1:08x} (want wfi)")
        elif ins2 != INS_B_SELF:
            ok = False
            msgs.append(f"BAD loop: 0x{ins2:08x} (want b .)")
        else:
            msgs.append(f"entry @ 0x{entry:x}     = wfi ; b .   (spin loop OK)")

    return ok, msgs


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Build an ARM64 `Image` placeholder kernel for Mi A1 (tissot)")
    ap.add_argument("--out", default=None,
                    help="output path (default: prebuilt/tissot-kernel-arm64.Image)")
    ap.add_argument("--size", type=int, default=DEFAULT_SIZE,
                    help=f"total image size in bytes (default {DEFAULT_SIZE})")
    args = ap.parse_args(argv)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)
    prebuilt = os.path.join(root_dir, "prebuilt")
    os.makedirs(prebuilt, exist_ok=True)

    out = args.out or os.path.join(prebuilt, "tissot-kernel-arm64.Image")

    print("=" * 62)
    print("  Mi A1 (tissot) ARM64 placeholder kernel builder")
    print("=" * 62)
    print()

    image = build_image(args.size)

    ok, msgs = verify_image(image)
    print("  Verification (parse-back of generated Image header):")
    for m in msgs:
        print(f"    {m}")
    print()

    if not ok:
        print("  ERROR: generated Image failed verification. Not writing.")
        return 1

    with open(out, "wb") as f:
        f.write(image)
    print(f"  Wrote: {os.path.relpath(out, root_dir)}  ({len(image)} bytes)")
    print()
    print("  This is a PLACEHOLDER. Real XNU ARM64 needs cctools + macOS SDK.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
