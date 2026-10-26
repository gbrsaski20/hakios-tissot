#!/usr/bin/env python3
"""
Build a Rufus-flashable .img file for HakiOS-x86 — entirely in Python.

This replaces tools/make-rufus-img.sh (which needs WSL/mtools).
It creates a raw disk image with:
  - MBR partition table
  - FAT32 EFI System Partition (ESP)
  - /EFI/BOOT/BOOTX64.EFI  (copy of xnuloader.efi — UEFI fallback)
  - /EFI/HAKIOS/xnuloader.efi
  - /EFI/HAKIOS/mach_kernel
  - /EFI/HAKIOS/cmdline.txt

Flash with Rufus:
  1. Open Rufus (https://rufus.ie)
  2. SELECT the .img file
  3. Partition scheme: GPT or MBR (both work with DD mode)
  4. Target system: UEFI (non-CSM)
  5. START — choose "DD Image" mode if asked
  6. Boot from USB

License: APSL 2.0
"""

import struct
import sys
import os
import time

# ============================================================================
# FAT32 Filesystem Implementation (minimal, no dependencies)
# ============================================================================

class FAT32Builder:
    """Build a minimal FAT32 filesystem image in memory."""

    def __init__(self, total_sectors, bytes_per_sector=512, sectors_per_cluster=8):
        self.bps = bytes_per_sector
        self.spc = sectors_per_cluster
        self.total_sectors = total_sectors
        self.cluster_size = self.spc * self.bps

        # FAT32 geometry
        self.reserved_sectors = 32
        self.num_fats = 2
        self.root_entries = 0  # FAT32 has no root directory in reserved area

        # Calculate FAT size
        data_sectors = total_sectors - self.reserved_sectors
        tmp_val = data_sectors / self.spc
        fats = (tmp_val * 4) + 1  # bytes per FAT
        sectors_per_fat = (int(fats) + bytes_per_sector - 1) // bytes_per_sector
        self.spf = sectors_per_fat

        # Data area
        self.data_sectors = total_sectors - self.reserved_sectors - (self.num_fats * self.spf)
        self.total_clusters = self.data_sectors // self.spc
        self.first_data_sector = self.reserved_sectors + (self.num_fats * self.spf)

        # FAT table
        self.fat = bytearray(self.spf * self.bps)

        # Mark cluster 0 and 1 as reserved/end-of-chain
        # Cluster 0: media descriptor + 0xFFFFFF00
        self.fat[0:4] = struct.pack('<I', 0x0FFFFFF8)  # media byte + status
        self.fat[4:8] = struct.pack('<I', 0x0FFFFFFF)  # end-of-chain marker for root dir

        # Root directory occupies cluster 2
        self.root_cluster = 2
        self.fat[8:12] = struct.pack('<I', 0x0FFFFFFF)  # root dir = 1 cluster, end-of-chain
        self.next_free_cluster = 3

        # Directory entries storage
        # Each entry is 32 bytes
        # root_dir_entries: list of 32-byte entries (placed at offset 0 of root cluster)
        self.root_dir_entries = []  # list of 32-byte bytearrays

        # File storage (cluster_num -> data)
        self.file_clusters = {}  # name -> list of cluster numbers
        self.cluster_data = {}   # cluster_num -> bytearray

    def _alloc_cluster(self):
        """Allocate a cluster and mark it as end-of-chain in FAT."""
        cl = self.next_free_cluster
        self.next_free_cluster += 1
        offset = cl * 4
        if offset + 4 <= len(self.fat):
            struct.pack_into('<I', self.fat, offset, 0x0FFFFFFF)
        return cl

    def _alloc_chain(self, num_clusters):
        """Allocate a chain of clusters."""
        clusters = []
        for _ in range(num_clusters):
            cl = self._alloc_cluster()
            clusters.append(cl)
        # Link them
        for i in range(len(clusters) - 1):
            offset = clusters[i] * 4
            struct.pack_into('<I', self.fat, offset, clusters[i + 1])
        # Last cluster already marked 0x0FFFFFFF
        return clusters

    def _cluster_to_sector(self, cluster):
        """Convert cluster number to absolute sector within the FS."""
        return self.first_data_sector + (cluster - 2) * self.spc

    def _make_short_name(self, name):
        """Convert a filename to 8.3 short name format (11 bytes)."""
        name = name.upper()
        if '.' in name:
            base, ext = name.rsplit('.', 1)
        else:
            base, ext = name, ''

        # Remove invalid chars, pad/truncate
        base = ''.join(c for c in base if c.isalnum() or c in '_-')[:8]
        ext = ''.join(c for c in ext if c.isalnum() or c in '_-')[:3]
        base = base.ljust(8)
        ext = ext.ljust(3)
        return (base + ext).encode('ascii')

    def _make_dir_entry(self, name, attr, cluster, size):
        """Create a 32-byte directory entry."""
        entry = bytearray(32)
        short_name = self._make_short_name(name)
        entry[0:11] = short_name
        entry[11] = attr  # attributes byte
        entry[12] = 0     # reserved (case info)
        entry[13] = 0     # creation time tenths
        # Creation time/date
        t = 0  # time: 0 = midnight
        d = ((2026 - 1980) << 9) | (10 << 5) | 26  # date: Oct 26, 2026
        struct.pack_into('<H', entry, 14, t)  # creation time
        struct.pack_into('<H', entry, 16, d)  # creation date
        struct.pack_into('<H', entry, 18, d)  # last access date
        struct.pack_into('<H', entry, 20, (cluster >> 16) & 0xFFFF)  # high cluster word
        struct.pack_into('<H', entry, 22, t)  # write time
        struct.pack_into('<H', entry, 24, d)  # write date
        struct.pack_into('<H', entry, 26, cluster & 0xFFFF)  # low cluster word
        struct.pack_into('<I', entry, 28, size)  # file size
        return entry

    def _make_lfn_entries(self, long_name, short_name_entry):
        """Create Long File Name directory entries."""
        # LFN: sequence number + name parts (UTF-16LE) + checksum of short name
        # Each LFN entry is 32 bytes
        # Fields: seq(1), name1[5](10), attr(1)=0x0F, type(1)=0, chksum(1),
        #         name2[6](12), first_cluster(2)=0, name3[2](4)

        # Calculate checksum of 8.3 name
        cksum = 0
        for b in short_name_entry[0:11]:
            cksum = ((cksum & 1) << 7) + (cksum >> 1) + b
            cksum &= 0xFF

        # Split name into UTF-16 characters
        chars = list(long_name)
        # Add null terminator and pad to fill entries
        # Each LFN entry holds 13 UTF-16 chars
        while len(chars) % 13 != 0:
            chars.append('\x00')

        num_entries = len(chars) // 13
        entries = []

        for i in range(num_entries - 1, -1, -1):
            entry = bytearray(32)
            seq = i + 1
            if i == num_entries - 1:
                seq |= 0x40  # last entry flag

            entry[0] = seq
            entry[11] = 0x0F  # LFN attribute
            entry[12] = 0     # type
            entry[13] = cksum

            # Get the 13 chars for this entry
            chunk = chars[i * 13: (i + 1) * 13]

            # Name part 1: chars 0-4 (10 bytes = 5 UTF-16)
            for j, ch in enumerate(chunk[0:5]):
                struct.pack_into('<H', entry, 1 + j * 2, ord(ch))

            # Name part 2: chars 5-10 (12 bytes = 6 UTF-16)
            for j, ch in enumerate(chunk[5:11]):
                struct.pack_into('<H', entry, 14 + j * 2, ord(ch))

            # Name part 3: chars 11-12 (4 bytes = 2 UTF-16)
            for j, ch in enumerate(chunk[11:13]):
                struct.pack_into('<H', entry, 28 + j * 2, ord(ch))

            entries.append(entry)

        return entries

    def add_file(self, name, data):
        """Add a file to the root directory."""
        num_clusters = max(1, (len(data) + self.cluster_size - 1) // self.cluster_size)
        clusters = self._alloc_chain(num_clusters)

        # Store file data in clusters
        for i, cl in enumerate(clusters):
            start = i * self.cluster_size
            end = min(start + self.cluster_size, len(data))
            cluster_data = bytearray(self.cluster_size)
            cluster_data[0:end - start] = data[start:end]
            self.cluster_data[cl] = cluster_data

        # Create directory entries (LFN + 8.3)
        short_entry = self._make_dir_entry(name, 0x20, clusters[0], len(data))
        lfn_entries = self._make_lfn_entries(name, short_entry)

        # Add to root directory
        for entry in lfn_entries:
            self.root_dir_entries.append(bytes(entry))
        self.root_dir_entries.append(bytes(short_entry))

        print(f"    Added: {name} ({len(data)} bytes, {num_clusters} clusters)")

    def add_directory(self, dirname, entries_data):
        """Add a subdirectory with files."""
        # Allocate a cluster for the directory
        dir_cluster = self._alloc_cluster()

        # Create directory data: . and .. entries, then files
        dir_data = bytearray(self.cluster_size)

        # . entry (points to itself)
        dot = self._make_dir_entry('.', 0x10, dir_cluster, 0)
        # .. entry (points to root = cluster 2)
        dotdot = self._make_dir_entry('..', 0x10, 2, 0)

        dir_data[0:32] = dot
        dir_data[32:64] = dotdot

        dir_offset = 64

        for name, data in entries_data:
            num_clusters = max(1, (len(data) + self.cluster_size - 1) // self.cluster_size)
            clusters = self._alloc_chain(num_clusters)

            for i, cl in enumerate(clusters):
                start = i * self.cluster_size
                end = min(start + self.cluster_size, len(data))
                cluster_data = bytearray(self.cluster_size)
                cluster_data[0:end - start] = data[start:end]
                self.cluster_data[cl] = cluster_data

            short_entry = self._make_dir_entry(name, 0x20, clusters[0], len(data))
            lfn_entries = self._make_lfn_entries(name, short_entry)

            for entry in lfn_entries:
                if dir_offset + 32 > len(dir_data):
                    # Need to extend to next cluster
                    next_cl = self._alloc_cluster()
                    struct.pack_into('<I', self.fat, dir_cluster * 4, next_cl)
                    self.cluster_data[dir_cluster] = dir_data
                    dir_cluster = next_cl
                    dir_data = bytearray(self.cluster_size)

                dir_data[dir_offset:dir_offset + 32] = entry
                dir_offset += 32

            if dir_offset + 32 > len(dir_data):
                next_cl = self._alloc_cluster()
                struct.pack_into('<I', self.fat, dir_cluster * 4, next_cl)
                self.cluster_data[dir_cluster] = dir_data
                dir_cluster = next_cl
                dir_data = bytearray(self.cluster_size)

            dir_data[dir_offset:dir_offset + 32] = short_entry
            dir_offset += 32

            print(f"    Added: {dirname}/{name} ({len(data)} bytes)")

        self.cluster_data[dir_cluster] = dir_data

        # Add directory entry in root
        short_entry = self._make_dir_entry(dirname, 0x10, self._cluster_to_sector(dir_cluster) and dir_cluster, 0)
        lfn_entries = self._make_lfn_entries(dirname, short_entry)

        for entry in lfn_entries:
            self.root_dir_entries.append(bytes(entry))
        self.root_dir_entries.append(bytes(short_entry))

    def _build_boot_sector(self, partition_start_lba):
        """Build the FAT32 boot sector (BPB)."""
        bs = bytearray(self.bps)

        # Jump instruction
        bs[0:3] = b'\xEB\x58\x90'  # jmp +0x5A; nop

        # OEM name (8 bytes)
        bs[3:11] = b'MSDOS5.0'

        # BPB
        struct.pack_into('<H', bs, 11, self.bps)            # BytesPerSector
        bs[13] = self.spc                                    # SectorsPerCluster
        struct.pack_into('<H', bs, 14, self.reserved_sectors) # ReservedSectors
        bs[16] = self.num_fats                               # NumFATs
        struct.pack_into('<H', bs, 17, 0)                    # RootEntries (0 for FAT32)
        struct.pack_into('<H', bs, 19, 0)                    # TotalSectors16 (0 = use 32-bit)
        bs[21] = 0xF8                                        # Media (hard disk)
        struct.pack_into('<H', bs, 22, 0)                    # FATsize16 (0 for FAT32)
        struct.pack_into('<H', bs, 24, 63)                   # SectorsPerTrack
        struct.pack_into('<H', bs, 26, 255)                  # NumHeads
        struct.pack_into('<I', bs, 28, partition_start_lba)  # HiddenSectors
        struct.pack_into('<I', bs, 32, self.total_sectors)   # TotalSectors32

        # Extended BPB (FAT32)
        struct.pack_into('<I', bs, 36, self.spf)             # FATsize32
        struct.pack_into('<H', bs, 40, 0)                    # ExtFlags
        bs[42] = 0                                           # FSVersion (low)
        bs[43] = 0                                           # FSVersion (high)
        struct.pack_into('<I', bs, 44, self.root_cluster)    # RootCluster
        struct.pack_into('<H', bs, 48, 1)                    # FSInfo sector
        struct.pack_into('<H', bs, 50, 6)                    # BkBootSec sector
        # Reserved bytes 52-63 (12 bytes)
        bs[64] = 0x80                                        # DriveNumber
        bs[65] = 0                                           # Reserved
        bs[66] = 0x29                                        # BootSignature
        struct.pack_into('<I', bs, 67, 0x12345678)           # VolumeID
        bs[71:82] = b'HAKIOS     '                   # VolumeLabel (11 bytes)
        bs[82:90] = b'FAT32   '                       # FileSystemType (8 bytes)

        # Boot signature at end of sector
        struct.pack_into('<H', bs, 510, 0xAA55)

        return bs

    def _build_fsinfo(self):
        """Build the FSInfo sector."""
        fi = bytearray(self.bps)
        struct.pack_into('<I', fi, 0, 0x41615252)    # LeadSignature
        struct.pack_into('<I', fi, 484, 0x61417272)  # StructSignature
        # Free count (0xFFFFFFFF = unknown)
        struct.pack_into('<I', fi, 488, 0xFFFFFFFF)
        struct.pack_into('<I', fi, 492, 0xFFFFFFFF)  # NextFree
        struct.pack_into('<H', fi, 510, 0xAA55)      # TrailSignature
        return fi

    def build(self, partition_start_lba):
        """Build the complete FAT32 filesystem image."""
        total_size = self.total_sectors * self.bps
        img = bytearray(total_size)

        # Boot sector
        bs = self._build_boot_sector(partition_start_lba)
        img[0:len(bs)] = bs

        # FSInfo sector
        fi = self._build_fsinfo()
        img[self.bps:2 * self.bps] = fi

        # Backup boot sector (sector 6)
        img[6 * self.bps:7 * self.bps] = bs

        # FAT tables
        fat_offset = self.reserved_sectors * self.bps
        for i in range(self.num_fats):
            offset = fat_offset + i * self.spf * self.bps
            img[offset:offset + len(self.fat)] = self.fat

        # Data area: write cluster data
        for cl, data in self.cluster_data.items():
            sector = self._cluster_to_sector(cl)
            offset = sector * self.bps
            if offset + len(data) <= len(img):
                img[offset:offset + len(data)] = data

        # Root directory is in cluster 2
        root_sector = self._cluster_to_sector(self.root_cluster)
        root_offset = root_sector * self.bps
        root_data = bytearray(self.cluster_size)
        offset = 0
        for entry in self.root_dir_entries:
            if offset + 32 > len(root_data):
                # Extend to next cluster
                break  # For now, single cluster root dir
            root_data[offset:offset + 32] = entry
            offset += 32
        img[root_offset:root_offset + len(root_data)] = root_data

        return bytes(img)


# ============================================================================
# MBR Partition Table
# ============================================================================

def write_mbr(img, partition_start_sector, num_sectors):
    """Write an MBR partition table with one EFI System Partition."""
    # MBR partition entry at offset 446 (first entry)
    # Format (16 bytes):
    #   0: boot flag (0x80 = active)
    #   1-3: CHS start (0xFE,0xFF,0xFF = use LBA)
    #   4: partition type (0xEF = EFI System Partition)
    #   5-7: CHS end (0xFE,0xFF,0xFF)
    #   8-11: LBA start (little-endian 32-bit)
    #   12-15: number of sectors (little-endian 32-bit)

    entry = struct.pack('<BBBBBBBBII',
        0x80,               # boot flag
        0xFE, 0xFF, 0xFF,   # CHS start
        0xEF,               # partition type (EFI System Partition)
        0xFE, 0xFF, 0xFF,   # CHS end
        partition_start_sector,
        num_sectors)

    # Write entry at offset 446
    img[446:462] = entry

    # MBR signature
    struct.pack_into('<H', img, 510, 0xAA55)


# ============================================================================
# Main
# ============================================================================

def main():
    print()
    print("=" * 50)
    print("  HakiOS-x86 Rufus Image Builder (Python)")
    print("=" * 50)
    print()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)  # tools/ -> root
    prebuilt_dir = os.path.join(root_dir, 'prebuilt')
    output_path = os.path.join(prebuilt_dir, 'hakios-x86.img')

    # Image geometry
    IMG_SIZE = 256 * 1024 * 1024  # 256 MB
    BPS = 512
    MBR_SIZE = 512
    PART_START = 1024 * 1024  # 1 MiB offset
    PART_START_SECTOR = PART_START // BPS  # 2048
    PART_SIZE = IMG_SIZE - PART_START
    PART_SECTORS = PART_SIZE // BPS

    print(f"  Output:    {output_path}")
    print(f"  Size:      {IMG_SIZE // 1024 // 1024} MB")
    print(f"  Partition: FAT32 ESP at sector {PART_START_SECTOR} ({PART_SECTORS} sectors)")
    print()

    # ---- Find built artifacts ----
    loader = None
    for f in [
        os.path.join(prebuilt_dir, 'xnuloader.efi'),
        os.path.join(root_dir, 'xnuloader', 'build', 'xnuloader.efi'),
    ]:
        if os.path.isfile(f):
            loader = f
            break

    kernel = None
    for f in [
        os.path.join(prebuilt_dir, 'mach.development.x86_64'),
        os.path.join(prebuilt_dir, 'mach.release.x86_64'),
        os.path.join(prebuilt_dir, 'mach.debug.x86_64'),
    ]:
        if os.path.isfile(f):
            kernel = f
            break

    if not loader:
        print("  ERROR: xnuloader.efi not found.")
        print("  Run: python xnuloader/build_efi.py")
        return 1

    if not kernel:
        print("  WARNING: mach_kernel not found. Image will be loader-only.")
        print("  Run: python tools/build_kernel_placeholder.py")
        kernel = None

    cmdline = "cpus=2 display=1 input=1 disk=1 net=1 serial=1"

    print(f"  Loader:  {loader}")
    if kernel:
        print(f"  Kernel:  {kernel}")
    else:
        print(f"  Kernel:  (none)")
    print(f"  Cmdline: {cmdline}")
    print()

    # ---- Read files ----
    with open(loader, 'rb') as f:
        loader_data = f.read()
    print(f"  Loader size: {len(loader_data)} bytes")

    kernel_data = None
    if kernel:
        with open(kernel, 'rb') as f:
            kernel_data = f.read()
        print(f"  Kernel size: {len(kernel_data)} bytes")

    cmdline_data = cmdline.encode('ascii')
    print()

    # ---- Build FAT32 filesystem ----
    print(">>> [1/4] Building FAT32 filesystem...")
    fat = FAT32Builder(PART_SECTORS, bytes_per_sector=BPS, sectors_per_cluster=8)

    # Add /EFI directory
    # We'll build the directory structure manually
    # Root -> EFI -> BOOT, HAKIOS

    # First, create EFI directory
    efi_dir_cluster = fat._alloc_cluster()
    efi_dir_data = bytearray(fat.cluster_size)

    # . and .. entries
    dot = fat._make_dir_entry('.', 0x10, efi_dir_cluster, 0)
    dotdot = fat._make_dir_entry('..', 0x10, fat.root_cluster, 0)
    efi_dir_data[0:32] = dot
    efi_dir_data[32:64] = dotdot
    efi_offset = 64

    # Create BOOT subdirectory inside EFI
    boot_dir_cluster = fat._alloc_cluster()
    boot_dir_data = bytearray(fat.cluster_size)
    bdot = fat._make_dir_entry('.', 0x10, boot_dir_cluster, 0)
    bdotdot = fat._make_dir_entry('..', 0x10, efi_dir_cluster, 0)
    boot_dir_data[0:32] = bdot
    boot_dir_data[32:64] = bdotdot
    boot_offset = 64

    # Copy BOOTX64.EFI into BOOT directory
    bootx64_clusters = fat._alloc_chain(max(1, (len(loader_data) + fat.cluster_size - 1) // fat.cluster_size))
    for i, cl in enumerate(bootx64_clusters):
        start = i * fat.cluster_size
        end = min(start + fat.cluster_size, len(loader_data))
        cd = bytearray(fat.cluster_size)
        cd[0:end - start] = loader_data[start:end]
        fat.cluster_data[cl] = cd

    bootx64_short = fat._make_dir_entry('BOOTX64.EFI', 0x20, bootx64_clusters[0], len(loader_data))
    bootx64_lfn = fat._make_lfn_entries('BOOTX64.EFI', bootx64_short)
    for entry in bootx64_lfn:
        if boot_offset + 32 > len(boot_dir_data):
            next_cl = fat._alloc_cluster()
            struct.pack_into('<I', fat.fat, boot_dir_cluster * 4, next_cl)
            fat.cluster_data[boot_dir_cluster] = boot_dir_data
            boot_dir_cluster = next_cl
            boot_dir_data = bytearray(fat.cluster_size)
        boot_dir_data[boot_offset:boot_offset + 32] = entry
        boot_offset += 32
    if boot_offset + 32 > len(boot_dir_data):
        next_cl = fat._alloc_cluster()
        struct.pack_into('<I', fat.fat, boot_dir_cluster * 4, next_cl)
        fat.cluster_data[boot_dir_cluster] = boot_dir_data
        boot_dir_cluster = next_cl
        boot_dir_data = bytearray(fat.cluster_size)
    boot_dir_data[boot_offset:boot_offset + 32] = bootx64_short
    boot_offset += 32
    fat.cluster_data[boot_dir_cluster] = boot_dir_data
    print(f"    /EFI/BOOT/BOOTX64.EFI <- xnuloader.efi ({len(loader_data)} bytes)")

    # Create HAKIOS subdirectory inside EFI
    hakios_dir_cluster = fat._alloc_cluster()
    hakios_dir_data = bytearray(fat.cluster_size)
    hdot = fat._make_dir_entry('.', 0x10, hakios_dir_cluster, 0)
    hdotdot = fat._make_dir_entry('..', 0x10, efi_dir_cluster, 0)
    hakios_dir_data[0:32] = hdot
    hakios_dir_data[32:64] = hdotdot
    hakios_offset = 64

    # Copy xnuloader.efi into HAKIOS directory
    loader_clusters = fat._alloc_chain(max(1, (len(loader_data) + fat.cluster_size - 1) // fat.cluster_size))
    for i, cl in enumerate(loader_clusters):
        start = i * fat.cluster_size
        end = min(start + fat.cluster_size, len(loader_data))
        cd = bytearray(fat.cluster_size)
        cd[0:end - start] = loader_data[start:end]
        fat.cluster_data[cl] = cd

    loader_short = fat._make_dir_entry('xnuloader.efi', 0x20, loader_clusters[0], len(loader_data))
    loader_lfn = fat._make_lfn_entries('xnuloader.efi', loader_short)
    for entry in loader_lfn:
        if hakios_offset + 32 > len(hakios_dir_data):
            next_cl = fat._alloc_cluster()
            struct.pack_into('<I', fat.fat, hakios_dir_cluster * 4, next_cl)
            fat.cluster_data[hakios_dir_cluster] = hakios_dir_data
            hakios_dir_cluster = next_cl
            hakios_dir_data = bytearray(fat.cluster_size)
        hakios_dir_data[hakios_offset:hakios_offset + 32] = entry
        hakios_offset += 32
    if hakios_offset + 32 > len(hakios_dir_data):
        next_cl = fat._alloc_cluster()
        struct.pack_into('<I', fat.fat, hakios_dir_cluster * 4, next_cl)
        fat.cluster_data[hakios_dir_cluster] = hakios_dir_data
        hakios_dir_cluster = next_cl
        hakios_dir_data = bytearray(fat.cluster_size)
    hakios_dir_data[hakios_offset:hakios_offset + 32] = loader_short
    hakios_offset += 32
    print(f"    /EFI/HAKIOS/xnuloader.efi")

    # Copy mach_kernel into HAKIOS directory
    if kernel_data:
        kernel_clusters = fat._alloc_chain(max(1, (len(kernel_data) + fat.cluster_size - 1) // fat.cluster_size))
        for i, cl in enumerate(kernel_clusters):
            start = i * fat.cluster_size
            end = min(start + fat.cluster_size, len(kernel_data))
            cd = bytearray(fat.cluster_size)
            cd[0:end - start] = kernel_data[start:end]
            fat.cluster_data[cl] = cd

        kernel_short = fat._make_dir_entry('mach_kernel', 0x20, kernel_clusters[0], len(kernel_data))
        kernel_lfn = fat._make_lfn_entries('mach_kernel', kernel_short)
        for entry in kernel_lfn:
            if hakios_offset + 32 > len(hakios_dir_data):
                next_cl = fat._alloc_cluster()
                struct.pack_into('<I', fat.fat, hakios_dir_cluster * 4, next_cl)
                fat.cluster_data[hakios_dir_cluster] = hakios_dir_data
                hakios_dir_cluster = next_cl
                hakios_dir_data = bytearray(fat.cluster_size)
            hakios_dir_data[hakios_offset:hakios_offset + 32] = entry
            hakios_offset += 32
        if hakios_offset + 32 > len(hakios_dir_data):
            next_cl = fat._alloc_cluster()
            struct.pack_into('<I', fat.fat, hakios_dir_cluster * 4, next_cl)
            fat.cluster_data[hakios_dir_cluster] = hakios_dir_data
            hakios_dir_cluster = next_cl
            hakios_dir_data = bytearray(fat.cluster_size)
        hakios_dir_data[hakios_offset:hakios_offset + 32] = kernel_short
        hakios_offset += 32
        print(f"    /EFI/HAKIOS/mach_kernel ({len(kernel_data)} bytes)")

    # Copy cmdline.txt into HAKIOS directory
    cmdline_clusters = fat._alloc_chain(max(1, (len(cmdline_data) + fat.cluster_size - 1) // fat.cluster_size))
    for i, cl in enumerate(cmdline_clusters):
        start = i * fat.cluster_size
        end = min(start + fat.cluster_size, len(cmdline_data))
        cd = bytearray(fat.cluster_size)
        cd[0:end - start] = cmdline_data[start:end]
        fat.cluster_data[cl] = cd

    cmdline_short = fat._make_dir_entry('cmdline.txt', 0x20, cmdline_clusters[0], len(cmdline_data))
    cmdline_lfn = fat._make_lfn_entries('cmdline.txt', cmdline_short)
    for entry in cmdline_lfn:
        if hakios_offset + 32 > len(hakios_dir_data):
            next_cl = fat._alloc_cluster()
            struct.pack_into('<I', fat.fat, hakios_dir_cluster * 4, next_cl)
            fat.cluster_data[hakios_dir_cluster] = hakios_dir_data
            hakios_dir_cluster = next_cl
            hakios_dir_data = bytearray(fat.cluster_size)
        hakios_dir_data[hakios_offset:hakios_offset + 32] = entry
        hakios_offset += 32
    if hakios_offset + 32 > len(hakios_dir_data):
        next_cl = fat._alloc_cluster()
        struct.pack_into('<I', fat.fat, hakios_dir_cluster * 4, next_cl)
        fat.cluster_data[hakios_dir_cluster] = hakios_dir_data
        hakios_dir_cluster = next_cl
        hakios_dir_data = bytearray(fat.cluster_size)
    hakios_dir_data[hakios_offset:hakios_offset + 32] = cmdline_short
    hakios_offset += 32
    print(f"    /EFI/HAKIOS/cmdline.txt")

    fat.cluster_data[hakios_dir_cluster] = hakios_dir_data

    # Add BOOT and HAKIOS entries to EFI directory
    boot_dir_short = fat._make_dir_entry('BOOT', 0x10, boot_dir_cluster, 0)
    efi_dir_data[efi_offset:efi_offset + 32] = boot_dir_short
    efi_offset += 32

    hakios_dir_short = fat._make_dir_entry('HAKIOS', 0x10, hakios_dir_cluster, 0)
    efi_dir_data[efi_offset:efi_offset + 32] = hakios_dir_short
    efi_offset += 32

    fat.cluster_data[efi_dir_cluster] = efi_dir_data

    # Add EFI entry to root directory
    efi_short = fat._make_dir_entry('EFI', 0x10, efi_dir_cluster, 0)
    fat.root_dir_entries.append(bytes(efi_short))

    # Build the FAT32 image
    fat_img = fat.build(PART_START_SECTOR)

    print()
    print(">>> [2/4] Creating raw disk image...")
    # Create the full image (MBR + partition)
    img = bytearray(IMG_SIZE)

    # Write MBR at offset 0
    print(">>> [3/4] Writing MBR partition table...")
    write_mbr(img, PART_START_SECTOR, PART_SECTORS)

    # Write FAT32 partition at PART_START
    print(">>> [4/4] Writing FAT32 filesystem...")
    img[PART_START:PART_START + len(fat_img)] = fat_img

    # Save
    os.makedirs(prebuilt_dir, exist_ok=True)
    with open(output_path, 'wb') as f:
        f.write(img)

    img_size_mb = os.path.getsize(output_path) / (1024 * 1024)
    print()
    print("=" * 50)
    print("  Rufus image created successfully!")
    print("=" * 50)
    print()
    print(f"  Output: {output_path}")
    print(f"  Size:   {img_size_mb:.1f} MB")
    print()
    print("  To flash with Rufus:")
    print("    1. Download Rufus from https://rufus.ie")
    print("    2. Open Rufus, click SELECT, choose:")
    print(f"       {output_path}")
    print("    3. Partition scheme: GPT")
    print("    4. Target system: UEFI (non-CSM)")
    print("    5. Click START")
    print("    6. If Rufus asks, choose 'DD Image' mode (NOT ISO mode)")
    print("    7. Boot from USB (enable UEFI in BIOS)")
    print()
    print("  Alternatively, flash with dd (if you have Git Bash):")
    print(f"    dd if={output_path} of=/dev/sdX bs=4M conv=fsync status=progress")
    print()

    return 0


if __name__ == '__main__':
    sys.exit(main())
