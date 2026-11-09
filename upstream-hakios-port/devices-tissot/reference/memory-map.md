# Mi A1 memory map as seen by the running OS (not yet used by any UEFI/loader)

Sources, both from one phone (TWRP, read-only `cat`): `dt/iomem.txt` (/proc/iomem), `dt/phone.dtb` (/sys/firmware/fdt, LineageOS 22).
They agree: the holes in `System RAM` are exactly the FDT's `no-map` reserved regions.

| range | what | source |
|---|---|---|
| 0x10000000-0x849fffff | System RAM | iomem (FDT `/memory` agrees) |
| 0x84a00000-0x867fffff | other_ext_region, no-map | FDT reserved-memory |
| 0x86800000-0x86bfffff | System RAM | iomem |
| 0x86c00000-0x8d5fffff | modem_region, no-map | FDT |
| 0x8d600000-0x8e7fffff | adsp_fw_region, no-map | FDT |
| 0x8e800000-0x8eefffff | wcnss_fw_region, no-map | FDT |
| 0x8ef00000-0x9fefffff | System RAM (splash/framebuffer at 0x90001000, 0x13ff000 bytes, is inside) | iomem, FDT |
| 0x9ff00000-0x9fffffff | pstore (persistent_ram), no-map | FDT, iomem |
| 0xa0000000-0xffffffff | System RAM | iomem |

Usable System RAM adds up to 0xe5e00000 bytes (3.59 GiB) on this phone.

Open points, nothing guessed here:
- RAM starting at 0x10000000 is unusual for an MSM8953 (DDR normally starts at 0x80000000). The Android kernel's "Kernel code"
  is at 0x10080000. Why is not known; it may be this phone's bootloader. Another Mi A1 could differ.
- Regions the FDT gives only a size for (secure_region, qseecom, adsp, gpu, venus, mem_dump) are placed by the OS at run time; their
  addresses are not in these files, so a firmware must not assume them free.
- The bootloader's own and TrustZone's memory is not visible here at all.
Peripheral windows seen: UARTDM 0x078af000 (earlycon), eMMC sdhci 0x07824900, GIC 0x0b000000/0x0b002000.
