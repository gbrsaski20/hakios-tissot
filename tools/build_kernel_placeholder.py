#!/usr/bin/env python3
"""
Build a placeholder mach_kernel for HakiOS-x86.

The real XNU kernel (xnu-8796.121.2) requires cctools-port + macOS SDK
to build on Linux, which are not always available. This script creates a
minimal placeholder kernel binary that:

  1. Is a valid x86_64 binary (ELF or raw)
  2. Contains a halt loop (hlt; jmp -2)
  3. Includes a banner string visible in hex dump
  4. Can be replaced later with the real mach_kernel

When the real kernel is built (via WSL/clang), it replaces this placeholder
in prebuilt/mach.development.x86_64.

License: APSL 2.0 (matches the XNU kernel it's a placeholder for)
"""

import struct
import sys
import os

def build_placeholder_kernel():
    """
    Build a minimal x86_64 kernel placeholder.

    The binary is a raw x86_64 image (not PE/ELF) that starts with
    a halt instruction. The xnuloader.efi loads this into memory and
    jumps to its entry point (offset 0).

    Layout:
      [x86_64 halt code]     -- entry point, halts CPU
      [banner string]        -- visible in hex dump
      [padding to 64KB]      -- realistic kernel size
    """
    code = bytearray()

    # --- Entry point: halt loop ---
    # cli (disable interrupts)
    code += b'\xfa'           # cli
    # hlt; jmp -2 (infinite halt loop)
    code += b'\xf4'           # hlt
    code += b'\xeb\xfd'      # jmp $-3 (back to hlt)

    # --- Banner (visible in hex dump) ---
    banner = b'\n'
    banner += b'  _    _    _  _  ___  ____   ____\n'
    banner += b' | |  | |  / \\| |/ _ \\/ ___| / ___|\n'
    banner += b' | |__| | / _ \\ | | | \\___ \\| |\n'
    banner += b' |  __  |/ ___ \\| |_| |___) | |___\n'
    banner += b' |_|  |_/_/   \\_\\\\___/|____/ \\____|\n'
    banner += b'\n'
    banner += b'  x86_64 | XNU kernel | HakiOS-x86\n'
    banner += b'\n'
    banner += b'  [PLACEHOLDER KERNEL]\n'
    banner += b'  This is a placeholder. The real XNU kernel\n'
    banner += b'  requires cctools + macOS SDK to build.\n'
    banner += b'  Build with WSL: build-windows.bat\n'
    banner += b'  Then mach_kernel replaces this file.\n'
    banner += b'\n'
    banner += b'  Status: Loader reached kernel entry point.\n'
    banner += b'  Next: Build real kernel with: make x86-open\n'
    banner += b'\x00'

    code += banner

    # --- Pad to 64KB (realistic minimal kernel size) ---
    target_size = 64 * 1024
    while len(code) < target_size:
        code += b'\x00'

    return bytes(code[:target_size])


def main():
    print("=" * 50)
    print("  HakiOS-x86 Placeholder Kernel Builder")
    print("=" * 50)
    print()

    kernel = build_placeholder_kernel()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)  # tools/ -> root
    prebuilt_dir = os.path.join(root_dir, 'prebuilt')

    os.makedirs(prebuilt_dir, exist_ok=True)

    # Write all three kernel config variants
    configs = ['development', 'release', 'debug']
    for cfg in configs:
        path = os.path.join(prebuilt_dir, f'mach.{cfg}.x86_64')
        with open(path, 'wb') as f:
            f.write(kernel)
        print(f"  Created: prebuilt/mach.{cfg}.x86_64 ({len(kernel)} bytes)")

    print()
    print("  NOTE: These are PLACEHOLDER kernels.")
    print("  The real XNU kernel requires:")
    print("    - cctools-port (for cross-compiling on Linux)")
    print("    - macOS SDK headers")
    print("    - clang 14+ with X86_64 target")
    print()
    print("  To build the real kernel, use WSL:")
    print("    build-windows.bat")
    print("  Or manually:")
    print("    xnu/apply.sh && xnu-deps/setup.sh && ./xnu-build-x86.sh")
    print()

    return 0


if __name__ == '__main__':
    sys.exit(main())
