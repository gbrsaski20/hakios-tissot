# edk2-msm port for Xiaomi Mi A1 (tissot, MSM8953): DRAFT, BUILDS, NEVER BOOTED

Overlay for https://github.com/edk2-porting/edk2-msm (tested against its pinned submodules). Derived from the SDM660 layer.

Built here: `boot-tissot.img` (Android boot image: BootShim + gzip(UEFI FD) + the phone's own DTB). **It has not been run on any phone.**

What it is: a minimal UEFI, GICv2 + arch timer + framebuffer console + shell. No storage, USB, touch or display drivers:
the vendor DXE drivers edk2-msm uses on other SoCs come from those phones' stock UEFI, and MSM8953 phones (LK bootloader) have none.

Values and where they came from:
- RAM, reserved regions, GIC, timer: a Mi A1's /proc/iomem and FDT (see ../upstream-hakios-port/devices-tissot/reference/memory-map.md). Only RAM at or above 0x8ef00000 is used.
- Framebuffer 0x90001000, 1080x1920x32: FDT splash_region and panel name; that LK scans out there is **assumed**.
- Boot image base 0x80000000, kernel +0x8000, ramdisk +0x01000000, tags +0x100, page 2048: usual MSM8953 LK layout, **not verified** against a Mi A1 boot.img.
- UEFI FD at 0xA0000000 (32 MiB): chosen from free RAM, untested.

Apply: copy the directories over an edk2-msm checkout, then `./build.sh -d tissot` (needs: clang, lld, gcc-aarch64-linux-gnu, gettext, nasm, python3, uuid-dev;
submodules: edk2, edk2-platforms, SimpleInit incl. freetype, EFI_Binaries; if gitlab.freedesktop.org is unreachable use github.com/freetype/freetype at the same commit).

Try (RAM only, writes nothing): `fastboot boot boot-tissot.img` with the phone in fastboot mode, bootloader unlocked.
If the screen stays dark, the likeliest causes are a wrong boot-image base/offset, the framebuffer address, or the memory map.
