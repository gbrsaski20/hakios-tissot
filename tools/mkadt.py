#!/usr/bin/env python3
"""
mkadt.py — Apple Device Tree (ADT) editor/generator for HakiOS / tissot.

Why this exists
---------------
XNU does NOT consume a Linux FDT. It consumes Apple's own **Device Tree**
format, parsed by `SecureDT*` (see pexpert/pexpert/device_tree.h):

    struct DeviceTreeNode {          // all fields little-endian
        uint32_t nProperties;
        uint32_t nChildren;
        DeviceTreeNodeProperty props[nProperties];
        DeviceTreeNode         children[nChildren];   // recursive
    };

    struct DeviceTreeNodeProperty {
        char     name[32];           // NUL padded
        uint32_t length;             // actual length = value & 0x7FFFFFFF
        uint8_t  value[length];      // padded to 4 bytes
    };

That layout was verified empirically against the real iPhone X ADT pulled from
the iOS 15.6.1 IPSW: a strict parse consumes the file byte-for-byte.

Strategy: template + override
-----------------------------
Building an ADT from scratch would mean re-creating every property XNU and
MobileGestalt expect (the real one has 18 top-level nodes, ~700 properties).
Instead we take the REAL d22ap ADT from the IPSW and only override what the
MSM8953 hardware needs. This is the same approach ios-sweet documents
("the device-tree builder copies /product from the real iPhone X device tree").

Keeping the iPhone X identity is intentional: MobileGestalt needs it.

What the tissot preset changes
------------------------------
`pe_arm_get_soc_base_phys()` (pexpert/arm/pe_identify_machine.c:181-201) does:

    gPESoCBasePhys = *(ranges_prop + 1);      // 2nd 64-bit word of "ranges"

and `serial_init()` bails out early if that is 0. So we set arm-io `ranges`
to { child=0, parent=0x07800000, size=0x10000000 } and give the serial node
`reg = { 0xAF000, 0x200 }` -> soc_base + reg = 0x078AF000, the real console.

Usage
-----
    # inspect the real ADT
    python tools/mkadt.py --template devices/tissot/dt/d22ap_15.6.1.adt --info

    # prove the writer is correct (parse -> write must be byte-identical)
    python tools/mkadt.py --template devices/tissot/dt/d22ap_15.6.1.adt --roundtrip

    # build the tissot ADT
    python tools/mkadt.py --template devices/tissot/dt/d22ap_15.6.1.adt \
                           --tissot --out prebuilt/tissot.adt
"""

import argparse
import os
import struct
import sys

PROP_NAME_LEN = 32
LEN_MASK = 0x7FFFFFFF
ALIGN = 4

# ---------------------------------------------------------------------------
# tissot hardware constants (verified against the stock Mi A1 device tree)
# ---------------------------------------------------------------------------
TISSOT_SOC_PARENT = 0x07800000      # arm-io ranges parent -> gPESoCBasePhys
TISSOT_SOC_SIZE = 0x10000000
TISSOT_UART_OFFSET = 0x000AF000     # 0x078AF000 - 0x07800000
TISSOT_UART_SIZE = 0x200

# GIC-400 (GICv2): distributor 0x0B000000, CPU interface 0x0B002000
TISSOT_GICD_OFFSET = 0x0B000000 - TISSOT_SOC_PARENT   # 0x03800000
TISSOT_GICD_SIZE = 0x1000
TISSOT_GICC_OFFSET = 0x0B002000 - TISSOT_SOC_PARENT   # 0x03802000
TISSOT_GICC_SIZE = 0x2000

# ARM generic timer PPIs
TISSOT_IRQ_TIMER_NS = 26
TISSOT_IRQ_TIMER_S = 27

# Clock tree (mainline qcom/msm8953.dtsi + stock tissot DT)
TISSOT_TIMEBASE_HZ = 19200000       # CNTFRQ_EL0 = 19.2 MHz
TISSOT_CPU_HZ = 2016000000          # Cortex-A53 max on MSM8953
TISSOT_BUS_HZ = 19200000
TISSOT_MEM_HZ = 1333000000

# DRAM base/size for Mi A1 (4 GiB window; usable is less, XNU trims it)
TISSOT_DRAM_BASE = 0x80000000
TISSOT_DRAM_SIZE = 0x100000000


# ---------------------------------------------------------------------------
# node model
# ---------------------------------------------------------------------------
class Node:
    __slots__ = ("props", "kids")

    def __init__(self):
        self.props = []   # list[(name:str, value:bytes, flag:int)]
        self.kids = []    # list[Node]

    # -- helpers -----------------------------------------------------------
    def name(self):
        for n, v, _f in self.props:
            if n == "name":
                return v.split(b"\x00")[0].decode("ascii", "replace")
        return ""

    def get(self, name):
        for n, v, _f in self.props:
            if n == name:
                return v
        return None

    def get_flag(self, name):
        for n, v, f in self.props:
            if n == name:
                return f
        return 0

    def set(self, name, value, flag=None):
        """Set (replace or append) a property.

        Apple sets the high bit of the length field on some properties; that
        bit is preserved when replacing an existing property, and defaults to
        0 for new ones.
        """
        if isinstance(value, str):
            value = value.encode("ascii")
        for i, (n, _v, f) in enumerate(self.props):
            if n == name:
                self.props[i] = (name, value, f if flag is None else flag)
                return self
        self.props.append((name, value, 0 if flag is None else flag))
        return self

    def remove(self, name):
        self.props = [p for p in self.props if p[0] != name]
        return self

    def child(self, name):
        for k in self.kids:
            if k.name() == name:
                return k
        return None

    def add_child(self, node):
        self.kids.append(node)
        return node

    def path(self, p):
        """Look up a node by slash-separated path relative to self."""
        cur = self
        for part in [x for x in p.split("/") if x]:
            cur = cur.child(part)
            if cur is None:
                return None
        return cur


# ---------------------------------------------------------------------------
# parse
# ---------------------------------------------------------------------------
def parse(buf):
    root, end = _parse_node(buf, 0, 0)
    if end != len(buf):
        raise ValueError(f"ADT parse consumed {end} of {len(buf)} bytes")
    return root


def _parse_node(buf, off, depth):
    if depth > 64:
        raise ValueError("ADT nesting too deep")
    if off + 8 > len(buf):
        raise ValueError("ADT truncated at node header")
    nprops, nkids = struct.unpack_from("<2I", buf, off)
    off += 8
    node = Node()

    for _ in range(nprops):
        if off + PROP_NAME_LEN + 4 > len(buf):
            raise ValueError("ADT truncated at property header")
        raw_name = buf[off:off + PROP_NAME_LEN]
        name = raw_name.split(b"\x00")[0].decode("ascii", "replace")
        raw_len = struct.unpack_from("<I", buf, off + PROP_NAME_LEN)[0]
        flag = raw_len & ~LEN_MASK
        length = raw_len & LEN_MASK
        off += PROP_NAME_LEN + 4
        if off + length > len(buf):
            raise ValueError(f"ADT property {name!r} runs past end")
        node.props.append((name, buf[off:off + length], flag))
        off += (length + ALIGN - 1) & ~(ALIGN - 1)

    for _ in range(nkids):
        kid, off = _parse_node(buf, off, depth + 1)
        node.kids.append(kid)

    return node, off


# ---------------------------------------------------------------------------
# serialise
# ---------------------------------------------------------------------------
def serialize(node):
    out = bytearray()
    _write_node(out, node)
    return bytes(out)


def _write_node(out, node):
    out += struct.pack("<2I", len(node.props), len(node.kids))
    for name, value, flag in node.props:
        nm = name.encode("ascii")
        if len(nm) > PROP_NAME_LEN - 1:
            raise ValueError(f"property name too long: {name!r}")
        out += nm.ljust(PROP_NAME_LEN, b"\x00")
        out += struct.pack("<I", len(value) | flag)
        out += value
        pad = (-len(value)) % ALIGN
        if pad:
            out += b"\x00" * pad
    for kid in node.kids:
        _write_node(out, kid)


# ---------------------------------------------------------------------------
# tisssot preset
# ---------------------------------------------------------------------------
def apply_tissot(root):
    """Override the iPhone X ADT with the minimum MSM8953 needs.

    Identity stays iPhone X (d22ap) on purpose: MobileGestalt depends on it.

    Every node written here is consumed by a specific line of XNU 8020:

      /arm-io:ranges            pe_arm_get_soc_base_phys()   -> soc base
      /arm-io/serial:reg        serial_init()                -> UART console
      /arm-io/gic:reg           pe_init_fiq() (GICv2 driver) -> interrupts
      /arm-io/gic-timebase:reg  pe_arm_map_interrupt_controller()
      /cpus/cpuN:*frequency*    pe_identify_machine()        -> clock info
      /memory:reg               arm_vm_init()                -> DRAM
    """
    changes = []

    # ---- arm-io: soc_base + a serial node XNU can find -------------------
    armio = root.child("arm-io")
    if armio is None:
        raise ValueError("template has no /arm-io node")

    # ranges: 3 x uint64 = { child, parent, size }  (2 address cells, 2 size cells)
    ranges = struct.pack("<3Q", 0, TISSOT_SOC_PARENT, TISSOT_SOC_SIZE)
    old = armio.get("ranges")
    armio.set("ranges", ranges)
    changes.append(f"/arm-io:ranges {len(old) if old else 0}B -> {len(ranges)}B "
                   f"(parent=0x{TISSOT_SOC_PARENT:x})")

    armio.set("device_type", b"msm8953-io\x00")
    armio.set("compatible", b"arm-io,msm8953\x00")
    changes.append("/arm-io:device_type/compatible -> msm8953")

    # replace any existing serial node, then add ours
    armio.kids = [k for k in armio.kids if k.name() != "serial"]
    ser = Node()
    ser.set("name", b"serial\x00")
    ser.set("compatible", b"qcom,msm-uartdm-v1.4\x00qcom,msm-uartdm\x00")
    ser.set("reg", struct.pack("<2Q", TISSOT_UART_OFFSET, TISSOT_UART_SIZE))
    ser.set("status", b"okay\x00")
    ser.set("AAPL,phandle", struct.pack("<I", 0x100))
    armio.add_child(ser)
    changes.append(f"/arm-io/serial: reg={{0x{TISSOT_UART_OFFSET:x}, "
                   f"0x{TISSOT_UART_SIZE:x}}} -> phys 0x"
                   f"{TISSOT_SOC_PARENT + TISSOT_UART_OFFSET:x}")

    # ---- interrupt controller: replace Apple AIC with GIC-400 (GICv2) ----
    #
    # The iPhone X ADT ships /arm-io/aic with interrupt-controller = "master".
    # pe_arm_map_interrupt_controller() does
    #     SecureDTFindEntry("interrupt-controller", "master", &entryP)
    # which is a first-match search, so the AIC node MUST go — otherwise XNU
    # maps Apple's AIC registers (0x32100000) instead of our GIC.
    armio.kids = [k for k in armio.kids if k.name() not in ("aic", "gic")]

    gic = Node()
    gic.set("name", b"gic\x00")
    gic.set("compatible", b"arm,gic-400\x00arm,cortex-a15-gic\x00")
    gic.set("device_type", b"interrupt-controller\x00")
    gic.set("interrupt-controller", b"master\x00")
    gic.set("#interrupt-cells", struct.pack("<I", 3))
    # GICv2 reg = <GICD base, GICD size, GICC base, GICC size>
    gic.set("reg", struct.pack("<4Q", TISSOT_GICD_OFFSET, TISSOT_GICD_SIZE,
                               TISSOT_GICC_OFFSET, TISSOT_GICC_SIZE))
    gic.set("AAPL,phandle", struct.pack("<I", 0x101))
    armio.add_child(gic)
    changes.append(f"/arm-io/aic -> /arm-io/gic (GICv2): GICD 0x"
                   f"{TISSOT_SOC_PARENT + TISSOT_GICD_OFFSET:x}, GICC 0x"
                   f"{TISSOT_SOC_PARENT + TISSOT_GICC_OFFSET:x}")

    # ---- timer node -----------------------------------------------------
    #
    # pe_arm_map_interrupt_controller() bails out (returns 0, aborting early
    # boot) if no node carries device_type = "timer". On arm64 the base it
    # maps is never actually dereferenced — ARM_ARCH_TIMER reads CNTFRQ_EL0 /
    # CNTPCT_EL0 — but the region still has to be mappable, so point it at
    # the GIC distributor rather than Apple's AIC timebase at 0x32108000.
    armio.kids = [k for k in armio.kids if k.name() not in ("aic-timebase", "gic-timebase")]

    tmr = Node()
    tmr.set("name", b"gic-timebase\x00")
    tmr.set("compatible", b"arm,armv8-timer\x00")
    tmr.set("device_type", b"timer\x00")
    tmr.set("reg", struct.pack("<2Q", TISSOT_GICD_OFFSET, TISSOT_GICD_SIZE))
    tmr.set("clock-frequency", struct.pack("<Q", TISSOT_TIMEBASE_HZ))
    tmr.set("AAPL,phandle", struct.pack("<I", 0x102))
    armio.add_child(tmr)
    changes.append(f"/arm-io/aic-timebase -> /arm-io/gic-timebase "
                   f"(device_type=timer, {TISSOT_TIMEBASE_HZ // 1000000} MHz)")

    # ---- cpus: real MSM8953 clock tree ----------------------------------
    #
    # The iPhone X ADT has state="running" (good — pe_identify_machine skips
    # CPUs without it) but every *frequency property is 0. A zero
    # timebase-frequency makes dec_clock_rate_hz 0, which then divides by
    # zero when computing bus_to_dec_rate_den. So these MUST be filled in.
    cpus = root.child("cpus")
    n_cpus = 0
    if cpus is not None:
        for cpu in cpus.kids:
            if cpu.get("state") is None:
                continue
            cpu.set("timebase-frequency", struct.pack("<Q", TISSOT_TIMEBASE_HZ))
            cpu.set("bus-frequency", struct.pack("<Q", TISSOT_BUS_HZ))
            cpu.set("memory-frequency", struct.pack("<Q", TISSOT_MEM_HZ))
            cpu.set("peripheral-frequency", struct.pack("<Q", TISSOT_BUS_HZ))
            cpu.set("fixed-frequency", struct.pack("<Q", TISSOT_TIMEBASE_HZ))
            cpu.set("clock-frequency", struct.pack("<Q", TISSOT_CPU_HZ))
            n_cpus += 1
        changes.append(f"/cpus: {n_cpus} cpu(s) -> timebase "
                       f"{TISSOT_TIMEBASE_HZ // 1000000} MHz, cpu "
                       f"{TISSOT_CPU_HZ // 1000000} MHz")

    # ---- memory: Mi A1 DRAM ---------------------------------------------
    mem = root.child("memory")
    if mem is not None:
        mem.set("reg", struct.pack("<2Q", TISSOT_DRAM_BASE, TISSOT_DRAM_SIZE))
        changes.append(f"/memory:reg 0x{TISSOT_DRAM_BASE:x} + "
                       f"0x{TISSOT_DRAM_SIZE:x}")

    # ---- mark the SoC so future code can detect the target --------------
    root.set("hakios,target", b"tissot\x00")
    changes.append("root:hakios,target = tissot")

    return changes


# ---------------------------------------------------------------------------
# verify: the nodes XNU actually reads must all be present and sane
# ---------------------------------------------------------------------------
def verify_xnu_requirements(root):
    """Check every ADT dependency XNU 8020 has, and report pass/fail.

    Each entry maps to a real call site, so a failure here means the kernel
    would panic or silently lose a subsystem.
    """
    checks = []

    def add(ok, what, detail=""):
        checks.append((ok, what, detail))

    # pe_arm_get_soc_base_phys() -> serial_init() early-returns when 0
    armio = root.child("arm-io")
    add(armio is not None, "/arm-io exists", "")
    if armio is not None:
        rng = armio.get("ranges")
        ok = rng is not None and len(rng) >= 16
        parent = struct.unpack("<2Q", rng[:16])[1] if ok else 0
        add(ok and parent != 0, "/arm-io:ranges parent != 0",
            f"parent=0x{parent:x}")

        ser = armio.child("serial")
        add(ser is not None, "/arm-io/serial exists",
            "" if ser is None else f"reg=0x{struct.unpack('<2Q', ser.get('reg'))[0]:x}")

        gic = armio.child("gic")
        add(gic is not None, "/arm-io/gic exists", "")
        if gic is not None:
            reg = gic.get("reg")
            add(reg is not None and len(reg) == 32,
                "/arm-io/gic:reg is 4x u64 (GICv2)",
                "" if reg is None else f"{len(reg)}B")
            ic = gic.get("interrupt-controller")
            add(ic is not None and ic.startswith(b"master"),
                "/arm-io/gic interrupt-controller=master",
                "" if ic is None else ic.rstrip(b"\x00").decode("ascii", "replace"))

        # exactly one node may claim interrupt-controller=master
        claimants = [k.name() for k in armio.kids
                     if (k.get("interrupt-controller") or b"").startswith(b"master")]
        add(len(claimants) == 1, "exactly one interrupt-controller=master",
            ", ".join(claimants) or "none")

        timers = [k.name() for k in armio.kids
                  if (k.get("device_type") or b"").startswith(b"timer")]
        add(len(timers) >= 1, "a node with device_type=timer",
            ", ".join(timers) or "none")

    # pe_identify_machine() asserts /cpus exists, then reads frequencies
    cpus = root.child("cpus")
    add(cpus is not None, "/cpus exists (pe_identify_machine asserts)", "")
    if cpus is not None:
        running = [c for c in cpus.kids
                   if (c.get("state") or b"").startswith(b"running")]
        add(len(running) > 0, "/cpus has state=running cpu(s)", f"{len(running)}")
        zero = [c.name() for c in running
                if struct.unpack("<Q", c.get("timebase-frequency") or b"\0" * 8)[0] == 0]
        add(not zero, "no cpu has timebase-frequency=0",
            ("zero: " + ", ".join(zero)) if zero else
            (f"{struct.unpack('<Q', running[0].get('timebase-frequency'))[0] // 1000000} MHz"
             if running else ""))

    mem = root.child("memory")
    add(mem is not None and len(mem.get("reg") or b"") == 16,
        "/memory:reg is 2x u64",
        "" if mem is None or not mem.get("reg") else
        f"0x{struct.unpack('<2Q', mem.get('reg'))[0]:x}")

    return checks


# ---------------------------------------------------------------------------
# info dump
# ---------------------------------------------------------------------------
def dump(node, depth=0, max_depth=2, prefix=""):
    name = node.name() or "(root)"
    print(f"{'  ' * depth}{prefix}{name}   props={len(node.props)} "
          f"kids={len(node.kids)}")
    if depth < max_depth:
        for k in node.kids:
            dump(k, depth + 1, max_depth)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(here)

    ap = argparse.ArgumentParser(
        description="Apple Device Tree (ADT) editor for HakiOS/tissot")
    ap.add_argument("--template", default=os.path.join(
        root_dir, "devices", "tissot", "dt", "d22ap_15.6.1.adt"),
        help="real iPhone X ADT extracted from the IPSW")
    ap.add_argument("--out", default=os.path.join(root_dir, "prebuilt",
                                                  "tissot.adt"))
    ap.add_argument("--info", action="store_true", help="dump the tree")
    ap.add_argument("--roundtrip", action="store_true",
                    help="verify parse->serialize is byte-identical")
    ap.add_argument("--tissot", action="store_true",
                    help="apply the tissot hardware overrides")
    args = ap.parse_args(argv)

    print("=" * 66)
    print("  Apple Device Tree (ADT) tool — HakiOS / tissot")
    print("=" * 66)

    if not os.path.isfile(args.template):
        print(f"  ERROR: template not found: {args.template}")
        print("         Extract it first:")
        print("           python tools/extract_adt.py <ipsw>")
        print("           (then decompress the .lzfse payload)")
        return 1

    buf = open(args.template, "rb").read()
    print(f"  template : {os.path.relpath(args.template, root_dir)}")
    print(f"  size     : {len(buf):,} bytes")

    try:
        root = parse(buf)
    except Exception as e:
        print(f"  ERROR: cannot parse template: {e}")
        return 1

    print(f"  root     : props={len(root.props)} kids={len(root.kids)}")
    print()

    if args.info:
        dump(root, 0, 2)
        return 0

    if args.roundtrip:
        again = serialize(root)
        ok = again == buf
        print(f"  roundtrip: {len(again):,} bytes, "
              f"{'BYTE-IDENTICAL ✅' if ok else 'DIFFERS ❌'}")
        if not ok:
            for i, (a, b) in enumerate(zip(buf, again)):
                if a != b:
                    print(f"  first diff at offset {i}: {a:02x} != {b:02x}")
                    break
            print(f"  (original {len(buf)}, rewritten {len(again)})")
            return 1
        print("  -> the writer is provably correct for this template.")
        return 0

    if args.tissot:
        try:
            changes = apply_tissot(root)
        except Exception as e:
            print(f"  ERROR applying tissot preset: {e}")
            return 1
        print("  tissot overrides:")
        for c in changes:
            print(f"    - {c}")
        print()

    out = serialize(root)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(out)
    print(f"  Wrote: {os.path.relpath(args.out, root_dir)}  ({len(out):,} bytes)")

    # self-check: re-parse what we wrote
    reparsed = parse(out)
    print(f"  re-parse OK: root props={len(reparsed.props)} "
          f"kids={len(reparsed.kids)}")

    ser = reparsed.child("arm-io").child("serial") if reparsed.child("arm-io") else None
    if ser is not None:
        reg = struct.unpack("<2Q", ser.get("reg"))
        rng = struct.unpack("<3Q", reparsed.child("arm-io").get("ranges"))
        print(f"  check: serial reg=0x{reg[0]:x} size=0x{reg[1]:x}, "
              f"ranges parent=0x{rng[1]:x}")
        print(f"         -> serial_init would map 0x{rng[1] + reg[0]:x} "
              f"(expected 0x{TISSOT_SOC_PARENT + TISSOT_UART_OFFSET:x})")
    print()

    # ---- XNU requirement audit -------------------------------------------
    checks = verify_xnu_requirements(reparsed)
    failed = [c for c in checks if not c[0]]
    print(f"  XNU 8020 requirement audit ({len(checks) - len(failed)}/"
          f"{len(checks)} pass):")
    for ok, what, detail in checks:
        mark = "OK  " if ok else "FAIL"
        suffix = f"  [{detail}]" if detail else ""
        print(f"    {mark} {what}{suffix}")
    print()

    if failed:
        print(f"  ERROR: {len(failed)} requirement(s) unmet — XNU would not boot")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
