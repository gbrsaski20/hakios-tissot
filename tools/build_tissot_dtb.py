#!/usr/bin/env python3
"""
build_tissot_dtb.py — Generate a valid Device Tree Blob (DTB) for
Xiaomi Mi A1 (codename: tissot, SoC: Qualcomm MSM8953 / Snapdragon 625).

Why this exists
---------------
`dtc` (device tree compiler) is not installed in the build environment, and
this project intentionally avoids external toolchains so the pipeline runs
anywhere. This script implements the Devicetree Specification (v0.4) FDT
binary format directly:

    +------------------+  offset 0
    |  FDT header (40) |   magic 0xd00dfeed, version 17, last_comp 16
    +------------------+  offset 40
    |  mem_rsvmap      |   one terminator entry (0,0) = 16 bytes
    +------------------+
    |  struct block    |   BEGIN_NODE / PROP / END_NODE / END tokens
    +------------------+
    |  strings block   |   null-terminated property names
    +------------------+

The resulting .dtb is a real, spec-conformant FDT that a bootloader /
`fdtdump` / `dtc -I dtb` can parse.

Output
------
    prebuilt/tissot.dtb      binary device tree
    prebuilt/tissot.dts      human-readable equivalent (for inspection)

Usage
-----
    python tools/build_tissot_dtb.py
    python tools/build_tissot_dtb.py --out prebuilt/tissot.dtb
"""

import argparse
import os
import struct
import sys

# ---------------------------------------------------------------------------
# FDT constants (Devicetree Specification v0.4, section 5)
# ---------------------------------------------------------------------------
FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 0x1
FDT_END_NODE = 0x2
FDT_PROP = 0x3
FDT_NOP = 0x4
FDT_END = 0x9

FDT_VERSION = 17
FDT_LAST_COMP_VERSION = 16


# ---------------------------------------------------------------------------
# Minimal FDT writer
# ---------------------------------------------------------------------------
class FDTBuilder:
    """Builds a flattened device tree (FDT) blob."""

    def __init__(self, boot_cpuid_phys=0):
        self.boot_cpuid_phys = boot_cpuid_phys
        self._struct = bytearray()
        self._strings = bytearray()
        self._str_offsets = {}
        self._depth = 0
        self._path = []

    # -- strings block ------------------------------------------------------
    def _string_offset(self, name):
        if name in self._str_offsets:
            return self._str_offsets[name]
        off = len(self._strings)
        self._strings += name.encode("ascii") + b"\x00"
        self._str_offsets[name] = off
        return off

    # -- structure block ----------------------------------------------------
    def begin_node(self, name):
        self._struct += struct.pack(">I", FDT_BEGIN_NODE)
        self._struct += name.encode("ascii") + b"\x00"
        self._pad_struct()
        self._path.append(name)
        self._depth += 1
        return self

    def end_node(self):
        if self._depth <= 0:
            raise ValueError("end_node() without matching begin_node()")
        self._struct += struct.pack(">I", FDT_END_NODE)
        self._depth -= 1
        if self._path:
            self._path.pop()
        return self

    def prop(self, name, value):
        """Add a property with a raw byte value."""
        if isinstance(value, str):
            value = value.encode("ascii") + b"\x00"
        self._struct += struct.pack(">III", FDT_PROP, len(value),
                                    self._string_offset(name))
        self._struct += value
        self._pad_struct()
        return self

    # -- typed helpers ------------------------------------------------------
    def prop_u32(self, name, *values):
        return self.prop(name, struct.pack(">" + "I" * len(values), *values))

    def prop_u64(self, name, *values):
        return self.prop(name, struct.pack(">" + "Q" * len(values), *values))

    def prop_string(self, name, *strings):
        """Stringlist: each string NUL-terminated, including the last."""
        payload = b"".join(s.encode("ascii") + b"\x00" for s in strings)
        return self.prop(name, payload)

    def prop_empty(self, name):
        """Boolean property (zero length)."""
        return self.prop(name, b"")

    def prop_bytes(self, name, data):
        return self.prop(name, bytes(data))

    # -- internals ----------------------------------------------------------
    def _pad_struct(self):
        while len(self._struct) % 4:
            self._struct += b"\x00"

    # -- serialise ----------------------------------------------------------
    def build(self):
        if self._depth != 0:
            raise ValueError(f"unbalanced nodes: depth={self._depth}")

        self._struct += struct.pack(">I", FDT_END)

        mem_rsvmap = struct.pack(">QQ", 0, 0)  # single terminator entry

        off_mem_rsvmap = 40  # header is exactly 40 bytes
        off_dt_struct = off_mem_rsvmap + len(mem_rsvmap)
        off_dt_strings = off_dt_struct + len(self._struct)
        totalsize = off_dt_strings + len(self._strings)

        header = struct.pack(
            ">10I",
            FDT_MAGIC,
            totalsize,
            off_dt_struct,
            off_dt_strings,
            off_mem_rsvmap,
            FDT_VERSION,
            FDT_LAST_COMP_VERSION,
            self.boot_cpuid_phys,
            len(self._strings),
            len(self._struct),
        )

        blob = bytes(header) + mem_rsvmap + bytes(self._struct) + bytes(self._strings)
        assert len(blob) == totalsize, "size accounting mismatch"
        return blob


# ---------------------------------------------------------------------------
# Xiaomi Mi A1 (tissot) / MSM8953 description
# ---------------------------------------------------------------------------
# Address map notes (Qualcomm MSM8953, "tissot"):
#   0x80000000  DRAM base (device tree "memory" node)
#   0x0B000000  QGIC2 distributor (GIC-400 class)
#   0x0B002000  QGIC2 CPU interface
#   0x078B0000  BLSP1 UART2  <- debug serial on tissot
#   0x078B6000  BLSP1 I2C4   (touch controller bus)
#   0x07824900  SDCC1        (eMMC)
#   0x07864000  SDCC2        (SD card)
# ---------------------------------------------------------------------------
DRAM_BASE = 0x80000000
DRAM_SIZE = 0x1_0000_0000  # placeholder: 4 GiB window (real usable ~3.5 GiB)


def build_tissot_fdt(bootargs=None, msm_id=(293, 0), board_id=(0x1000B, 0)):
    """Construct the FDT for Mi A1 / MSM8953.

    msm_id / board_id are emitted as `qcom,msm-id` / `qcom,board-id`.
    Qualcomm's ABL bootloader uses those to pick the right DT; without a
    matching `qcom,msm-id` it can refuse to boot the image.

    Values below come from the real device trees (verified 2026-10-27):
      * qcom,board-id = <0x1000b 0>
        -> LineageOS/android_kernel_xiaomi_msm8953, arch/arm64/boot/dts/qcom/
           msm8953-qrd-sku3-tissot.dts
      * msm-id 293 = MSM8953
      * console UART 0x78af000 (ttyHSL0), from the stock cmdline:
           console=ttyHSL0 earlycon=msm_hsl_uart,0x78af000
      * touch: FocalTech FT5435 on BLSP1 I2C4 (0x78b6000)
    """

    if bootargs is None:
        # Stock tissot cmdline (verified from the real stock boot.img, V10.0.24.0)
        bootargs = (
            "console=ttyHSL0,115200,n8 "
            "androidboot.console=ttyHSL0 "
            "androidboot.hardware=qcom "
            "msm_rtb.filter=0x237 "
            "ehci-hcd.park=3 "
            "lpm_levels.sleep_disabled=1 "
            "androidboot.bootdevice=7824900.sdhci "
            "earlycon=msm_hsl_uart,0x78af000 "
            "buildvariant=user"
        )

    b = FDTBuilder(boot_cpuid_phys=0)

    # ---- root ----
    b.begin_node("")
    b.prop_u32("#address-cells", 2)
    b.prop_u32("#size-cells", 2)
    b.prop_string("model", "Xiaomi Mi A1 (tissot)")
    b.prop_string("compatible", "xiaomi,tissot", "qcom,msm8953")
    if msm_id:
        b.prop_u32("qcom,msm-id", *msm_id)
    if board_id:
        b.prop_u32("qcom,board-id", *board_id)
    b.prop_u32("interrupt-parent", 0x1)  # phandle of intc below (placeholder)

    # ---- chosen ----
    b.begin_node("chosen")
    b.prop_string("bootargs", bootargs)
    b.prop_string("stdout-path", "/soc/serial@78af000")
    b.end_node()

    # ---- aliases ----
    b.begin_node("aliases")
    b.prop_string("serial0", "/soc/serial@78af000")
    b.end_node()

    # ---- memory ----
    b.begin_node("memory@80000000")
    b.prop_string("device_type", "memory")
    b.prop_u64("reg", 0x0, DRAM_BASE, 0x0, DRAM_SIZE)
    b.end_node()

    # ---- cpus: 8 x Cortex-A53 ----
    b.begin_node("cpus")
    b.prop_u32("#address-cells", 1)
    b.prop_u32("#size-cells", 0)
    for cpu in range(8):
        b.begin_node(f"cpu@{cpu:x}")
        b.prop_string("device_type", "cpu")
        b.prop_string("compatible", "arm,cortex-a53")
        b.prop_u32("reg", cpu)
        b.prop_string("enable-method", "psci")
        b.end_node()
    b.end_node()

    # ---- psci ----
    b.begin_node("psci")
    b.prop_string("compatible", "arm,psci-1.0", "arm,psci-0.2")
    b.prop_string("method", "smc")
    b.prop_u32("cpu_suspend", 0xC4000001)
    b.prop_u32("cpu_off", 0x84000002)
    b.prop_u32("cpu_on", 0xC4000003)
    b.end_node()

    # ---- interrupt controller: QGIC2 ----
    b.begin_node("interrupt-controller@b000000")
    b.prop_string("compatible", "qcom,msm-qgic2")
    b.prop_empty("interrupt-controller")
    b.prop_u32("#interrupt-cells", 3)
    b.prop_u64("reg",
               0x0, 0x0B000000, 0x0, 0x1000,   # distributor
               0x0, 0x0B002000, 0x0, 0x2000)   # cpu interface
    b.end_node()

    # ---- architected timer ----
    b.begin_node("timer")
    b.prop_string("compatible", "arm,armv8-timer")
    b.prop_u32("interrupts",
               1, 13, 0xF08,   # secure physical
               1, 14, 0xF08,   # non-secure physical
               1, 11, 0xF08,   # virtual
               1, 10, 0xF08)   # hypervisor
    b.prop_empty("always-on")
    b.end_node()

    # ---- soc: simple-bus ----
    b.begin_node("soc")
    b.prop_string("compatible", "simple-bus")
    b.prop_u32("#address-cells", 1)
    b.prop_u32("#size-cells", 1)
    b.prop_empty("ranges")

    # ---- debug / console UART: ttyHSL0 @ 0x78af000 ----
    # msm8953.dtsi: reg <0x78af000 0x200>, interrupts <0 107 0>
    b.begin_node("serial@78af000")
    b.prop_string("compatible", "qcom,msm-uartdm-v1.4", "qcom,msm-uartdm")
    b.prop_u32("reg", 0x078AF000, 0x200)
    b.prop_u32("interrupts", 0, 107, 0)
    b.prop_string("status", "okay")
    b.end_node()

    # ---- BLSP1 UART2 @ 0x78b0000 (HSUART, not the console) ----
    b.begin_node("uart@78b0000")
    b.prop_string("compatible", "qcom,msm-hsuart-v14")
    b.prop_u32("reg", 0x078B0000, 0x200, 0x07884000, 0x1F000)
    b.prop_string("status", "disabled")
    b.end_node()

    # ---- touch controller bus: BLSP1 QUP3 = i2c@78b7000 ----
    # Verified from the real stock DTB: focaltech@38 lives on i2c@78b7000
    # (NOT 78b6000 — that one hosts the audio codecs / LED driver).
    b.begin_node("i2c@78b7000")
    b.prop_string("compatible", "qcom,i2c-msm-v2")
    b.prop_u32("reg", 0x078B7000, 0x600)
    b.prop_u32("interrupts", 0, 97, 0)
    b.prop_u32("#address-cells", 1)
    b.prop_u32("#size-cells", 0)
    b.prop_u32("qcom,clk-freq-out", 400000)
    b.prop_string("status", "okay")

    # touchscreen: FocalTech FT5435 (stock DTS also lists focaltech@40,
    # synaptics_dsx@20, imagis@50 — different panel batches)
    b.begin_node("focaltech@38")
    b.prop_string("compatible", "focaltech,fts")
    b.prop_u32("reg", 0x38)
    b.prop_u32("interrupt-parent", 0x1)
    b.prop_u32("interrupts", 0, 0x41, 0x2)
    b.prop_u32("focaltech,family-id", 0x54)
    b.prop_string("status", "okay")
    b.end_node()

    b.end_node()  # i2c@78b7000

    # ---- eMMC: sdhci@7824900 (SDCC1) ----
    b.begin_node("sdhci@7824900")
    b.prop_string("compatible", "qcom,sdhci-msm")
    b.prop_u32("reg", 0x07824900, 0x500, 0x07824000, 0x800)
    b.prop_u32("interrupts", 0, 123, 0, 0, 138, 0)
    b.prop_string("status", "okay")
    b.prop_u32("bus-width", 8)
    b.prop_empty("non-removable")
    b.end_node()

    # ---- SD card: sdhci@7864900 (SDCC2) ----
    # NOTE: the node base is 0x7864900 (not 0x7864000) — verified in msm8953.dtsi
    b.begin_node("sdhci@7864900")
    b.prop_string("compatible", "qcom,sdhci-msm")
    b.prop_u32("reg", 0x07864900, 0x500, 0x07864000, 0x800)
    b.prop_u32("interrupts", 0, 125, 0, 0, 221, 0)
    b.prop_string("status", "okay")
    b.prop_u32("bus-width", 4)
    b.end_node()

    b.end_node()  # /soc
    b.end_node()  # /

    return b.build()


# ---------------------------------------------------------------------------
# Human-readable .dts (for inspection only; not consumed by anything)
# ---------------------------------------------------------------------------
TISSOT_DTS = """/dts-v1/;

/*
 * Xiaomi Mi A1 (tissot) — Qualcomm MSM8953 / Snapdragon 625
 * Auto-generated equivalent of prebuilt/tissot.dtb
 * Generated by tools/build_tissot_dtb.py
 */

/ {
    #address-cells = <2>;
    #size-cells = <2>;
    model = "Xiaomi Mi A1 (tissot)";
    compatible = "xiaomi,tissot", "qcom,msm8953";
    qcom,msm-id = <0x125 0x0>;      /* 293 = MSM8953 */
    qcom,board-id = <0x1000b 0x0>;  /* real tissot value (msm8953-qrd-sku3-tissot.dts) */
    interrupt-parent = <&intc>;

    chosen {
        bootargs = "console=ttyHSL0,115200,n8 androidboot.console=ttyHSL0 "
                   "androidboot.hardware=qcom "
                   "msm_rtb.filter=0x237 ehci-hcd.park=3 "
                   "lpm_levels.sleep_disabled=1 "
                   "androidboot.bootdevice=7824900.sdhci "
                   "earlycon=msm_hsl_uart,0x78af000 "
                   "buildvariant=user";
        stdout-path = "/soc/serial@78af000";
    };

    aliases {
        serial0 = "/soc/serial@78af000";
    };

    memory@80000000 {
        device_type = "memory";
        reg = <0x0 0x80000000 0x0 0x100000000>;
    };

    cpus {
        #address-cells = <1>;
        #size-cells = <0>;

        cpu@0 { device_type = "cpu"; compatible = "arm,cortex-a53"; reg = <0x0>; enable-method = "psci"; };
        cpu@1 { device_type = "cpu"; compatible = "arm,cortex-a53"; reg = <0x1>; enable-method = "psci"; };
        cpu@2 { device_type = "cpu"; compatible = "arm,cortex-a53"; reg = <0x2>; enable-method = "psci"; };
        cpu@3 { device_type = "cpu"; compatible = "arm,cortex-a53"; reg = <0x3>; enable-method = "psci"; };
        cpu@4 { device_type = "cpu"; compatible = "arm,cortex-a53"; reg = <0x4>; enable-method = "psci"; };
        cpu@5 { device_type = "cpu"; compatible = "arm,cortex-a53"; reg = <0x5>; enable-method = "psci"; };
        cpu@6 { device_type = "cpu"; compatible = "arm,cortex-a53"; reg = <0x6>; enable-method = "psci"; };
        cpu@7 { device_type = "cpu"; compatible = "arm,cortex-a53"; reg = <0x7>; enable-method = "psci"; };
    };

    psci {
        compatible = "arm,psci-1.0", "arm,psci-0.2";
        method = "smc";
        cpu_suspend = <0xc4000001>;
        cpu_off     = <0x84000002>;
        cpu_on      = <0xc4000003>;
    };

    intc: interrupt-controller@b000000 {
        compatible = "qcom,msm-qgic2";
        interrupt-controller;
        #interrupt-cells = <3>;
        reg = <0x0 0x0b000000 0x0 0x1000>,
              <0x0 0x0b002000 0x0 0x2000>;
    };

    timer {
        compatible = "arm,armv8-timer";
        interrupts = <1 13 0xf08>, <1 14 0xf08>, <1 11 0xf08>, <1 10 0xf08>;
        always-on;
    };

    soc {
        compatible = "simple-bus";
        #address-cells = <1>;
        #size-cells = <1>;
        ranges;

        serial@78af000 {          /* console / ttyHSL0 */
            compatible = "qcom,msm-uartdm-v1.4", "qcom,msm-uartdm";
            reg = <0x078af000 0x200>;
            interrupts = <0 107 0>;
            status = "okay";
        };

        uart@78b0000 {            /* HSUART, not the console */
            compatible = "qcom,msm-hsuart-v14";
            reg = <0x078b0000 0x200>, <0x07884000 0x1f000>;
            status = "disabled";
        };

        i2c@78b7000 {             /* BLSP1 QUP3 — touch bus (NOT 78b6000) */
            compatible = "qcom,i2c-msm-v2";
            reg = <0x078b7000 0x600>;
            interrupts = <0 97 0>;
            #address-cells = <1>;
            #size-cells = <0>;
            qcom,clk-freq-out = <400000>;
            status = "okay";

            focaltech@38 {        /* FocalTech FT5435 touchscreen */
                compatible = "focaltech,fts";
                reg = <0x38>;
                interrupt-parent = <&intc>;
                interrupts = <0 0x41 0x2>;
                focaltech,family-id = <0x54>;
                status = "okay";
            };
        };

        sdhci@7824900 {           /* eMMC (SDCC1) */
            compatible = "qcom,sdhci-msm";
            reg = <0x07824900 0x500>, <0x07824000 0x800>;
            interrupts = <0 123 0>, <0 138 0>;
            bus-width = <8>;
            non-removable;
            status = "okay";
        };

        sdhci@7864900 {           /* SD card (SDCC2) */
            compatible = "qcom,sdhci-msm";
            reg = <0x07864900 0x500>, <0x07864000 0x800>;
            interrupts = <0 125 0>, <0 221 0>;
            bus-width = <4>;
            status = "okay";
        };
    };
};
"""


# ---------------------------------------------------------------------------
# Verification: parse the DTB back and sanity-check it
# ---------------------------------------------------------------------------
def verify_dtb(blob):
    """Parse header + walk the struct block. Returns (ok, messages)."""
    msgs = []
    if len(blob) < 40:
        return False, ["blob shorter than FDT header"]

    (magic, totalsize, off_struct, off_strings, off_rsvmap,
     version, last_comp, boot_cpuid, size_strings, size_struct) = struct.unpack(
        ">10I", blob[:40])

    ok = True
    if magic != FDT_MAGIC:
        ok = False
        msgs.append(f"BAD magic: 0x{magic:08x} (expected 0xd00dfeed)")
    else:
        msgs.append(f"magic            = 0x{magic:08x}  (FDT_MAGIC, OK)")

    if totalsize != len(blob):
        ok = False
        msgs.append(f"BAD totalsize: {totalsize} != actual {len(blob)}")
    else:
        msgs.append(f"totalsize        = {totalsize} bytes (matches file)")

    if not (40 <= off_struct < totalsize and off_struct + size_struct <= totalsize):
        ok = False
        msgs.append("BAD off_dt_struct / size_dt_struct out of range")
    else:
        msgs.append(f"off_dt_struct    = {off_struct} (size {size_struct})")

    if not (off_strings + size_strings <= totalsize):
        ok = False
        msgs.append("BAD off_dt_strings / size_dt_strings out of range")
    else:
        msgs.append(f"off_dt_strings   = {off_strings} (size {size_strings})")

    if off_rsvmap != 40:
        ok = False
        msgs.append(f"BAD off_mem_rsvmap = {off_rsvmap} (expected 40)")
    else:
        msgs.append(f"off_mem_rsvmap   = {off_rsvmap} (immediately after header)")

    msgs.append(f"version          = {version} / last_comp {last_comp}")
    msgs.append(f"boot_cpuid_phys  = {boot_cpuid}")

    # Walk tokens
    pos = off_struct
    end = off_struct + size_struct
    depth = 0
    nodes = []
    props = 0
    while pos + 4 <= end:
        (tok,) = struct.unpack(">I", blob[pos:pos + 4])
        pos += 4
        if tok == FDT_BEGIN_NODE:
            nul = blob.index(b"\x00", pos)
            name = blob[pos:nul].decode("ascii", "replace")
            pos = (nul + 1 + 3) & ~3
            nodes.append(name or "/")
            depth += 1
        elif tok == FDT_END_NODE:
            depth -= 1
        elif tok == FDT_PROP:
            (plen, nameoff) = struct.unpack(">II", blob[pos:pos + 8])
            pos += 8
            pos = (pos + plen + 3) & ~3
            props += 1
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            break
        else:
            ok = False
            msgs.append(f"BAD token 0x{tok:x} at offset {pos - 4}")
            break

    if depth != 0:
        ok = False
        msgs.append(f"BAD unbalanced nodes, depth={depth} at END")

    msgs.append(f"nodes parsed     = {len(nodes)}, properties = {props}")
    msgs.append("node tree        = " + ", ".join("/" + n if n != "/" else "/"
                                                  for n in nodes))
    return ok, msgs


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Generate a valid DTB for Xiaomi Mi A1 (tissot/MSM8953)")
    ap.add_argument("--out", default=None,
                    help="output .dtb path (default: prebuilt/tissot.dtb)")
    ap.add_argument("--no-dts", action="store_true",
                    help="do not also write the .dts text file")
    ap.add_argument("--msm-id", nargs=2, type=int, default=[293, 0],
                    metavar=("ID", "VER"),
                    help="qcom,msm-id (default: 293 0 = MSM8953)")
    ap.add_argument("--board-id", nargs=2, type=int, default=[0x1000B, 0],
                    metavar=("ID", "VER"),
                    help="qcom,board-id (default: 0x1000b 0 = real tissot value "
                         "from msm8953-qrd-sku3-tissot.dts)")
    args = ap.parse_args(argv)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)
    prebuilt = os.path.join(root_dir, "prebuilt")
    os.makedirs(prebuilt, exist_ok=True)

    out_dtb = args.out or os.path.join(prebuilt, "tissot.dtb")

    print("=" * 62)
    print("  Mi A1 (tissot / MSM8953) Device Tree Blob generator")
    print("=" * 62)
    print()

    blob = build_tissot_fdt(
        msm_id=tuple(args.msm_id) if args.msm_id else None,
        board_id=tuple(args.board_id) if args.board_id else None,
    )

    ok, msgs = verify_dtb(blob)
    print("  Verification (parse-back of generated blob):")
    for m in msgs:
        print(f"    {m}")
    print()

    if not ok:
        print("  ERROR: generated DTB failed verification. Not writing.")
        return 1

    with open(out_dtb, "wb") as f:
        f.write(blob)
    print(f"  Wrote: {os.path.relpath(out_dtb, root_dir)}  ({len(blob)} bytes)")

    if not args.no_dts:
        out_dts = os.path.splitext(out_dtb)[0] + ".dts"
        with open(out_dts, "w", encoding="utf-8") as f:
            f.write(TISSOT_DTS)
        print(f"  Wrote: {os.path.relpath(out_dts, root_dir)}  (readable source)")

    print()
    print("  Note: this DT describes the REAL MSM8953 silicon.")
    print("  The ios-sweet approach instead feeds XNU a FAKED iPhone X")
    print("  (d22ap) DT; see docs/PORT-TISSOT.md section 4.3.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
