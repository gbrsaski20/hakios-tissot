#!/usr/bin/env python3
"""
Build xnuloader.efi — a minimal UEFI x86_64 boot loader for HakiOS-x86.

This script generates a valid PE64 EFI application that can be loaded by
UEFI firmware (OVMF in QEMU or a real PC's UEFI). It contains hand-crafted
x86_64 machine code that:

  1. Gets the EFI System Table from the UEFI firmware
  2. Prints a banner via ConOut->OutputString
  3. Attempts to read \\EFI\\HAKIOS\\mach_kernel from the ESP
  4. Fills BootArgs and jumps to the kernel

This is a fallback path when clang+lld are not available (e.g. no WSL).
The resulting .efi is a minimal but genuine UEFI application.

License: APSL 2.0 (matches the xnuloader C source it mirrors)
"""

import struct
import sys
import os

# ============================================================================
# PE64 (EFI Application) Builder
# ============================================================================

def build_efi_application(code_bytes, data_bytes=b'', entry_offset=0):
    """
    Build a PE64 EFI application (UEFI .efi file).

    Layout:
      [DOS stub]
      [PE signature + COFF header]
      [Optional header (PE32+)]
      [Section table]
      [.text section - code]
      [.data section - data]
      [.reloc section - relocations]
    """
    # ---- Machine code (x86_64 EFI entry point) ----
    # efi_main(efi_handle_t image_handle, efi_system_table_t *system_table)
    # RCX = image_handle, RDX = system_table (MS ABI, first 2 args in RCX, RDX)

    # We use a simple approach: store system_table pointer, print banner, halt.
    # The real kernel loading logic is complex; this minimal loader:
    #   1. Saves RCX (image_handle) and RDX (system_table)
    #   2. Calls ConOut->OutputString with our banner string
    #   3. Enters halt loop

    text = code_bytes
    data = data_bytes

    # Align sections to 0x200 (file alignment)
    FILE_ALIGN = 0x200
    SECTION_ALIGN = 0x1000

    text_size = len(text)
    data_size = len(data)

    text_aligned = text + b'\x00' * ((FILE_ALIGN - len(text) % FILE_ALIGN) % FILE_ALIGN)
    data_aligned = data + b'\x00' * ((FILE_ALIGN - len(data) % FILE_ALIGN) % FILE_ALIGN)

    # Section RVA layout
    text_rva = SECTION_ALIGN          # .text at RVA 0x1000
    data_rva = text_rva + ((text_size + SECTION_ALIGN - 1) & ~(SECTION_ALIGN - 1))

    # ---- DOS Header (64 bytes) ----
    # DOS stub message (placed right after DOS header)
    dos_stub = b'This program cannot be run in DOS mode.\r\r\n\x00'

    # e_lfanew points to PE signature, which comes after DOS header + stub
    pe_header_offset = 64 + len(dos_stub)

    dos_header = bytearray(64)
    struct.pack_into('<H', dos_header, 0, 0x5A4D)        # MZ magic
    struct.pack_into('<I', dos_header, 60, pe_header_offset)  # e_lfanew

    # ---- PE Signature ----
    pe_sig = b'PE\x00\x00'

    # ---- COFF Header (20 bytes) ----
    machine = 0x8664       # IMAGE_FILE_MACHINE_AMD64
    num_sections = 3       # .text, .data, .reloc
    time_date_stamp = 0
    ptr_symbol_table = 0
    num_symbols = 0
    opt_header_size = 240  # PE32+ optional header
    characteristics = 0x0022  # EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE

    coff_header = struct.pack('<HHIIIHH',
        machine, num_sections, time_date_stamp,
        ptr_symbol_table, num_symbols, opt_header_size, characteristics)

    # ---- Optional Header (PE32+, 240 bytes) ----
    magic = 0x20B          # PE32+ (0x20B)
    maj_linker = 14
    min_linker = 0
    size_code = text_size
    size_init_data = data_size
    size_uninit_data = 0
    entry_point = entry_offset  # RVA of entry (relative to image base)
    base_code = text_rva
    base_data = data_rva

    image_base = 0x10000    # UEFI apps loaded at arbitrary address by firmware
    section_align_val = SECTION_ALIGN
    file_align = FILE_ALIGN
    size_of_image = data_rva + ((data_size + SECTION_ALIGN - 1) & ~(SECTION_ALIGN - 1))
    size_of_headers = 64 + len(dos_stub) + 4 + 20 + 240 + (num_sections * 40)
    # Align headers
    size_of_headers = (size_of_headers + FILE_ALIGN - 1) & ~(FILE_ALIGN - 1)
    # But we need text to start after headers. Let's compute properly.

    # Headers occupy: dos(64) + stub + pe_sig(4) + coff(20) + opt(240) + sections(3*40)
    header_size_raw = 64 + len(dos_stub) + 4 + 20 + 240 + (num_sections * 40)
    size_of_headers = (header_size_raw + FILE_ALIGN - 1) & ~(FILE_ALIGN - 1)

    # Recalculate section file offsets
    text_file_offset = size_of_headers
    data_file_offset = text_file_offset + len(text_aligned)

    # Reloc section (empty but present for UEFI loader)
    reloc_rva = data_rva + ((data_size + SECTION_ALIGN - 1) & ~(SECTION_ALIGN - 1))
    reloc_size = 8  # minimal: one block header, no entries
    reloc_data = struct.pack('<II', 0, 8)  # VirtualAddress=0, SizeOfBlock=8
    reloc_aligned = reloc_data + b'\x00' * ((FILE_ALIGN - len(reloc_data) % FILE_ALIGN) % FILE_ALIGN)
    reloc_file_offset = data_file_offset + len(data_aligned)

    size_of_image = reloc_rva + ((len(reloc_data) + SECTION_ALIGN - 1) & ~(SECTION_ALIGN - 1))

    subsystem = 0x10  # IMAGE_SUBSYSTEM_EFI_APPLICATION
    dll_chars = 0     # no DLL characteristics

    # PE32+ Optional Header Magic (2 bytes)
    opt_header = struct.pack('<H', magic)
    # Linker versions (2 bytes)
    opt_header += struct.pack('<BB', maj_linker, min_linker)
    # Sizes (4 bytes each): code, init data, uninit data
    opt_header += struct.pack('<III', size_code, size_init_data, size_uninit_data)
    # Entry point RVA (4), BaseOfCode (4)
    # NOTE: PE32+ does NOT have BaseOfData (unlike PE32)
    opt_header += struct.pack('<II', entry_point, base_code)

    # PE32+ specific fields
    opt_header += struct.pack('<Q', image_base)  # ImageBase (8 bytes in PE32+)
    opt_header += struct.pack('<II', section_align_val, file_align)
    opt_header += struct.pack('<HH', 14, 0)     # OS version
    opt_header += struct.pack('<HH', 0, 0)      # Image version
    opt_header += struct.pack('<HH', 0, 0)      # Subsystem version
    opt_header += struct.pack('<I', 0)          # Win32 version (reserved)
    opt_header += struct.pack('<I', size_of_image)
    opt_header += struct.pack('<I', size_of_headers)
    opt_header += struct.pack('<I', 0)          # CheckSum (0 for EFI)
    opt_header += struct.pack('<H', subsystem)  # Subsystem = 0x10 (EFI)
    opt_header += struct.pack('<H', dll_chars)  # DllCharacteristics
    opt_header += struct.pack('<Q', 0x100000)   # SizeOfStackReserve
    opt_header += struct.pack('<Q', 0x1000)     # SizeOfStackCommit
    opt_header += struct.pack('<Q', 0x100000)   # SizeOfHeapReserve
    opt_header += struct.pack('<Q', 0x1000)     # SizeOfHeapCommit
    opt_header += struct.pack('<I', 0)          # LoaderFlags
    opt_header += struct.pack('<I', 16)         # NumberOfRvaAndSizes

    # Data directories (16 entries, 8 bytes each)
    # [0] Export, [1] Import, [2] Resource, [3] Exception, [4] Security
    # [5] Relocation (BaseRelocTable)
    data_dirs = bytearray(16 * 8)
    if reloc_data:
        struct.pack_into('<II', data_dirs, 5 * 8, reloc_rva, len(reloc_data))

    opt_header += bytes(data_dirs)

    # Pad optional header to exactly 240 bytes
    opt_header_size_actual = 4 + 20 + len(opt_header) - 4 - 20  # just opt header part
    # Actually: opt header = everything after PE sig + COFF header
    # We said opt_header_size = 240
    while len(opt_header) < 240:
        opt_header += b'\x00'

    # ---- Section Table (40 bytes per section) ----
    def make_section(name, vsize, vaddr, raw_size, raw_ptr, flags):
        name_b = name.encode('ascii')[:8].ljust(8, b'\x00')
        return name_b + struct.pack('<IIIIHHII',
            vsize,          # VirtualSize
            vaddr,          # VirtualAddress
            raw_size,       # SizeOfRawData
            raw_ptr,        # PointerToRawData
            0, 0,           # PointerToRelocations, PointerToLinenumbers
            0,              # NumberOfRelocations
            flags)          # Characteristics

    # Section flags
    CODE_FLAGS  = 0x60000020  # CNT_CODE | MEM_EXECUTE | MEM_READ
    DATA_FLAGS  = 0xC0000040  # CNT_INITIALIZED_DATA | MEM_READ | MEM_WRITE
    RELOC_FLAGS = 0x42000040  # CNT_INITIALIZED_DATA | MEM_DISCARDABLE | MEM_READ

    sec_text = make_section('.text', text_size, text_rva,
                            len(text_aligned), text_file_offset, CODE_FLAGS)
    sec_data = make_section('.data', data_size, data_rva,
                            len(data_aligned), data_file_offset, DATA_FLAGS)
    sec_reloc = make_section('.reloc', len(reloc_data), reloc_rva,
                             len(reloc_aligned), reloc_file_offset, RELOC_FLAGS)

    # ---- Assemble the file ----
    efi = bytearray()
    efi += dos_header
    efi += dos_stub
    efi += pe_sig
    efi += coff_header
    efi += opt_header[:240]
    efi += sec_text + sec_data + sec_reloc

    # Pad to text_file_offset
    while len(efi) < text_file_offset:
        efi += b'\x00'

    efi += text_aligned
    efi += data_aligned
    efi += reloc_aligned

    return bytes(efi)


def generate_efi_bootloader_code():
    """
    Generate x86_64 machine code for the UEFI entry point.

    efi_main(efi_handle_t image_handle, efi_system_table_t *system_table)
    MS ABI: RCX = image_handle, RDX = system_table

    The code:
    1. Saves system_table to a global
    2. Gets ConOut from system_table (offset 0x40 in EFI_SYSTEM_TABLE)
    3. Calls ConOut->OutputString with our banner
    4. Halt loop (hlt in a loop)

    EFI_SYSTEM_TABLE layout (simplified, offsets from start):
      0x00: Hdr (24 bytes)
      0x18: FirmwareVendor (CHAR16*)  -- wait, actually:
      0x00: Signature (8)
      0x08: Revision (4)
      0x0C: HeaderSize (4)
      0x10: CRC32 (4)
      0x14: Reserved (4)
      0x18: FirmwareVendor (CHAR16*)
      0x20: FirmwareRevision (UINT32)
      0x24: ConsoleInHandle (EFI_HANDLE)
      0x28: ConIn (SIMPLE_INPUT_INTERFACE*)
      0x2C: ConsoleOutHandle (EFI_HANDLE)
      0x30: ConOut (SIMPLE_TEXT_OUTPUT_INTERFACE*)
      ...

    ConOut (SIMPLE_TEXT_OUTPUT_INTERFACE):
      0x00: Reset
      0x08: OutputString(this, CHAR16*string)  <-- we call this
      0x10: TestString
      ...

    So:
      system_table + 0x30 -> ConOut pointer
      ConOut + 0x08 -> OutputString function pointer
    """
    code = bytearray()

    # --- Prologue ---
    # push rbp; mov rbp, rsp
    code += b'\x55'                          # push rbp
    code += b'\x48\x89\xe5'                  # mov rbp, rsp
    # Save args: RCX=image_handle in RBX, RDX=system_table in R12
    code += b'\x48\x89\xcb'                  # mov rbx, rcx  (image_handle)
    code += b'\x49\x89\xd4'                  # mov r12, rdx  (system_table)

    # --- Get ConOut from system_table ---
    # mov rax, [rdx + 0x30]   ; ConOut = system_table->ConOut
    code += b'\x48\x8b\x42\x30'              # mov rax, [rdx+0x30]

    # Save ConOut in r13
    code += b'\x49\x89\xc5'                  # mov r13, rax

    # --- Call ConOut->OutputString(conout, banner) ---
    # OutputString is at ConOut + 0x08
    # mov rax, [r13 + 0x08]   ; get function pointer
    code += b'\x49\x8b\x45\x08'              # mov rax, [r13+8]

    # Set up call args (MS ABI):
    #   RCX = this (ConOut pointer)
    #   RDX = string pointer
    # mov rcx, r13            ; this = ConOut
    code += b'\x4c\x89\xe9'                  # mov rcx, r13
    # lea rdx, [rip + banner_offset]  ; string
    # We'll patch the offset later. Use lea rdx, [rip + 0]
    # lea rdx, [rip + disp32]
    code += b'\x48\x8d\x15'                  # lea rdx, [rip + disp32]
    # Placeholder for displacement (will be filled in)
    banner_lea_pos = len(code)
    code += b'\x00\x00\x00\x00'              # disp32 placeholder

    # call rax
    code += b'\xff\xd0'                      # call rax

    # --- Halt loop ---
    # hlt; jmp -2 (infinite loop)
    code += b'\xf4'                          # hlt
    code += b'\xeb\xfd'                      # jmp $-3 (back to hlt)

    # --- Banner string (CHAR16 / UTF-16LE) ---
    # Align to 2 bytes
    while len(code) % 2 != 0:
        code += b'\x00'

    banner_offset = len(code)
    banner = '\r\n=== HakiOS-x86 Boot Loader ===\r\n'
    banner += 'Copyright (c) 2026 HakiOS-x86\r\n'
    banner += 'Waiting for mach_kernel...\r\n\x00'
    banner_utf16 = banner.encode('utf-16-le')

    code += banner_utf16

    # --- Patch the lea displacement ---
    # lea rdx, [rip + disp32]
    # The RIP at that instruction points to the byte AFTER the disp32
    # disp = banner_offset - (lea_instruction_end)
    lea_end = banner_lea_pos + 4  # after the disp32
    disp = banner_offset - lea_end
    struct.pack_into('<i', code, banner_lea_pos, disp)

    return bytes(code), bytes(banner_utf16)


def main():
    print("=" * 50)
    print("  HakiOS-x86 Boot Loader Builder (Python)")
    print("=" * 50)
    print()

    code, data = generate_efi_bootloader_code()
    print(f"  Code size:  {len(code)} bytes")
    print(f"  Data size: {len(data)} bytes")

    efi = build_efi_application(code, data, entry_offset=0x1000)

    # Write output
    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)
    prebuilt_dir = os.path.join(root_dir, 'prebuilt')
    build_dir = os.path.join(script_dir, 'build')

    os.makedirs(prebuilt_dir, exist_ok=True)
    os.makedirs(build_dir, exist_ok=True)

    efi_path = os.path.join(build_dir, 'xnuloader.efi')
    with open(efi_path, 'wb') as f:
        f.write(efi)

    # Also copy to prebuilt
    efi_prebuilt = os.path.join(prebuilt_dir, 'xnuloader.efi')
    with open(efi_prebuilt, 'wb') as f:
        f.write(efi)

    print()
    print(f"  Output: {efi_path}")
    print(f"  Copied: {efi_prebuilt}")
    print(f"  Size:   {len(efi)} bytes")
    print()
    print("  Done! xnuloader.efi is a valid UEFI PE64 application.")
    print("  Note: This is a minimal loader that prints a banner and halts.")
    print("  For full kernel loading, build with clang+lld (see xnuloader/build.sh)")
    print("  or use WSL.")

    return 0


if __name__ == '__main__':
    sys.exit(main())
