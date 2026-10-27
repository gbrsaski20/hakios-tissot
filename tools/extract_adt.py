#!/usr/bin/env python3
"""
extract_adt.py — Extract the iPhone X (d22ap) Apple Device Tree from an IPSW.

Background
----------
The IPSW entry `Firmware/all_flash/DeviceTree.d22ap.im4p` is not a raw file.
It is an **IMG4** container, which is plain DER:

    SEQ {
      IA5 "IM4P"
      IA5 "dtre"                                  <- payload type
      IA5 "EmbeddedDeviceTrees-7153.140.37.700.2" <- description
      OCT <payload>                               <- the device tree
      SEQ { INT .., INT .. }                      <- (partial manifest here)
    }

For iOS 16 the OCT payload is **LZFSE-compressed** (starts with "bvx2"), which
is why ios-sweet runs `ipsw img4 im4p extract` — that tool decompresses it.

This script:
  1. Reads the .im4p straight out of the IPSW zip (no full extraction needed)
  2. Parses the DER / IMG4 wrapper
  3. Detects the payload encoding (LZFSE / LZVN / raw FDT / raw ADT)
  4. Decompresses when it can, and writes the .adt
  5. Otherwise writes the compressed blob and tells you the exact command to run

Usage
-----
    python tools/extract_adt.py F:\\SETUP\\iPhone10,3,iPhone10,6_15.6.1_19G82_Restore.ipsw
    python tools/extract_adt.py <ipsw> --device d221ap --out somewhere/
    python tools/extract_adt.py <ipsw> --list

Requirements
------------
* Reading + DER parsing: standard library only.
* LZFSE decompression needs either the `lzfse` Python module
  (`pip install lzfse`) or the `ipsw` CLI (`ipsw img4 im4p extract`).
  Without either, the script still extracts the raw compressed payload.
"""

import argparse
import os
import struct
import sys
import zipfile

# ---------------------------------------------------------------------------
# minimal DER (ASN.1 TLV) reader
# ---------------------------------------------------------------------------
TAG_SEQ = 0x30
TAG_SET = 0x31
TAG_IA5 = 0x16
TAG_OCT = 0x04


def der_tlv(buf, pos=0):
    """Return (tag, value_bytes, next_pos)."""
    if pos + 2 > len(buf):
        raise ValueError("truncated DER")
    tag = buf[pos]
    pos += 1
    length = buf[pos]
    pos += 1
    if length & 0x80:
        n = length & 0x7F
        if n == 0 or pos + n > len(buf):
            raise ValueError("bad DER length")
        length = int.from_bytes(buf[pos:pos + n], "big")
        pos += n
    if pos + length > len(buf):
        raise ValueError("DER value runs past end of buffer")
    return tag, buf[pos:pos + length], pos + length


def parse_img4(blob):
    """Parse an IMG4 (DER) or IM4P (binary) container.

    Returns dict: {"strings": [...], "payload": bytes, "container": "IMG4"|"IM4P"}
    """
    if blob[:4] == b"IM4P":
        # Binary IM4P: magic, u32 hdr_len, type, desc, data
        hdr_len = struct.unpack(">I", blob[4:8])[0]
        typ = blob[8:12]
        nul = blob.index(b"\x00", 12)
        desc = blob[12:nul]
        return {
            "container": "IM4P",
            "strings": ["IM4P", typ.decode("ascii", "replace"),
                        desc.decode("ascii", "replace")],
            "payload": blob[hdr_len:],
        }

    tag, value, _ = der_tlv(blob, 0)
    if tag not in (TAG_SEQ, TAG_SET):
        raise ValueError(f"not an IMG4/IM4P container (first tag 0x{tag:02x})")

    strings, payload = [], None
    pos = 0
    while pos < len(value):
        t, v, pos = der_tlv(value, pos)
        if t == TAG_IA5:
            strings.append(v.decode("ascii", "replace"))
        elif t == TAG_OCT and payload is None:
            payload = v
        elif t in (TAG_SEQ, TAG_SET):
            # nested: recurse one level (IM4P may be wrapped in its own SEQ)
            inner_pos = 0
            while inner_pos < len(v):
                t2, v2, inner_pos = der_tlv(v, inner_pos)
                if t2 == TAG_IA5:
                    strings.append(v2.decode("ascii", "replace"))
                elif t2 == TAG_OCT and payload is None:
                    payload = v2

    if payload is None:
        raise ValueError("no OCTET STRING payload found in IMG4")
    return {"container": "IMG4", "strings": strings, "payload": payload}


# ---------------------------------------------------------------------------
# payload encoding detection / decompression
# ---------------------------------------------------------------------------
def detect_encoding(payload):
    if payload[:4] == b"bvx2":
        return "lzfse"
    if payload[:4] == b"bvxn":
        return "lzvn"
    if payload[:4] == b"bvx$":
        return "lzfse-uncompressed"
    if payload[:4] == b"\xd0\x0d\xfe\xed":
        return "fdt"
    if payload[:4] == b"complzss" or payload[:4] == b"comp":
        return "lzss-kernelcache"
    return "raw/adt"


def try_lzfse_decompress(payload):
    """Return (data, method) or (None, reason)."""
    # 1. python module
    try:
        import lzfse  # type: ignore
        return lzfse.decompress(payload), "python-lzfse"
    except ImportError:
        pass
    except Exception as e:  # module present but failed
        return None, f"python-lzfse error: {e}"

    # 2. `ipsw` CLI fallback would need a file on disk; caller handles it.
    return None, "python module 'lzfse' not installed"


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Extract the iPhone X Apple Device Tree (ADT) from an IPSW")
    ap.add_argument("ipsw", help="path to the .ipsw file")
    ap.add_argument("--device", default="d22ap",
                    help="device tree suffix to extract (default: d22ap = iPhone X)")
    ap.add_argument("--out", default=None,
                    help="output directory (default: devices/tissot/dt)")
    ap.add_argument("--list", action="store_true",
                    help="only list the DeviceTree entries and exit")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.ipsw):
        print(f"ERROR: IPSW not found: {args.ipsw}")
        return 1

    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)
    out_dir = args.out or os.path.join(root_dir, "devices", "tissot", "dt")
    os.makedirs(out_dir, exist_ok=True)

    z = zipfile.ZipFile(args.ipsw)
    dt_entries = [n for n in z.namelist() if "DeviceTree" in n]

    print("=" * 66)
    print("  iPhone X (d22ap) Apple Device Tree extractor")
    print("=" * 66)
    print(f"  IPSW   : {args.ipsw}")
    print(f"  Device : {args.device}")
    print()
    print("  DeviceTree entries in this IPSW:")
    for n in dt_entries:
        print(f"    {n}")
    print()

    if args.list:
        return 0

    entry = next((n for n in dt_entries if n.endswith(f"DeviceTree.{args.device}.im4p")), None)
    if not entry:
        print(f"ERROR: no DeviceTree.{args.device}.im4p in this IPSW.")
        return 1

    blob = z.read(entry)
    info = parse_img4(blob)
    payload = info["payload"]
    enc = detect_encoding(payload)

    print(f"  Entry      : {entry}")
    print(f"  Container  : {info['container']}")
    print(f"  Strings    : {info['strings']}")
    print(f"  File size  : {len(blob)} bytes")
    print(f"  Payload    : {len(payload)} bytes")
    print(f"  Encoding   : {enc}  (magic {payload[:4]!r})")
    print()

    im4p_path = os.path.join(out_dir, os.path.basename(entry))
    with open(im4p_path, "wb") as f:
        f.write(blob)
    print(f"  Wrote: {os.path.relpath(im4p_path, root_dir)}")

    if enc in ("fdt", "raw/adt"):
        adt_path = os.path.join(out_dir, f"{args.device}.adt")
        with open(adt_path, "wb") as f:
            f.write(payload)
        print(f"  Wrote: {os.path.relpath(adt_path, root_dir)}  (uncompressed)")
        print()
        print("  Note: a raw FDT here would mean a Linux device tree.")
        print("        XNU expects an Apple Device Tree (ADT), which mkadt.py builds.")
        return 0

    # compressed
    raw_path = os.path.join(out_dir, f"{args.device}.adt.{enc}")
    with open(raw_path, "wb") as f:
        f.write(payload)
    print(f"  Wrote: {os.path.relpath(raw_path, root_dir)}  (still compressed)")

    data, how = try_lzfse_decompress(payload) if enc.startswith("lzfse") else (None, "not lzfse")
    if data:
        adt_path = os.path.join(out_dir, f"{args.device}.adt")
        with open(adt_path, "wb") as f:
            f.write(data)
        print(f"  Decompressed via {how} -> "
              f"{os.path.relpath(adt_path, root_dir)}  ({len(data)} bytes)")
        print(f"  first 32 bytes: {data[:32].hex(' ')}")
        return 0

    print()
    print(f"  Could not decompress ({how}).")
    print("  Pick one of these:")
    print("    1) pip install lzfse          # then re-run this script")
    print("    2) install blacktop/ipsw and run:")
    print(f"         ipsw img4 im4p extract {os.path.relpath(im4p_path, root_dir)} "
          f"-o {os.path.relpath(os.path.join(out_dir, args.device + '.adt'), root_dir)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
