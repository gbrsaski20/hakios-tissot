# Device profile: Xiaomi Mi A1 (codename `tissot`)

This is an **ios-sweet-style** ARM port target: run iOS natively on the
Mi A1's ARM64 SoC (no emulation, no x86 anywhere in this repo).
Goal: run **iOS 15.6.1 (19G82)** — iPhone X (`d22ap`) userland — **natively**
on the Mi A1's ARM64 SoC.

## Hardware

| Item | Value |
|------|-------|
| Model | Xiaomi Mi A1 (Android One) |
| Codename | `tissot` |
| SoC | Qualcomm MSM8953 (Snapdragon 625) |
| CPU | 8× Cortex-A53, **ARMv8.0-A** |
| RAM | 4 GB |
| Bootloader | Unlockable via Xiaomi Mi Unlock |

## Why this target
- ARM-on-ARM: iOS ARM64 binaries run native (no emulation).
- Cortex-A53 has **no PAC** (Pointer Authentication) — same gate iPhone X satisfied.

## Why it is risky
- MSM8953 is **ARMv8.0** (2017); the confirmed ios-sweet ports run on
  **ARMv8.2-class** SoCs. That is exactly why this port uses **iOS 15, not 16**:
  iOS 15 still ships to the iPhone 6s (A9, ARMv8.0), so its `arm64` userland
  cannot use ARMv8.1/8.2 instructions. See `docs/IOS15-VS-IOS16-ARMv8.md`.
- Still unproven: whether XNU 8020 itself stays within ARMv8.0 when compiled
  with `-mcpu=cortex-a53`. Source scan found no LSE/FP16 usage, which supports
  it, but only hardware will confirm.

## Files in this folder
| File | Purpose |
|------|---------|
| `README.md` | This profile |
| `extract-dt.sh` | Template: fetch Mi A1 stock device tree from firmware |
| `build-bootimage.sh` | **Working**: builds a flashable boot image via the Python tools |
| `dt/` | Working dir for device trees (iPhone X `d22ap` + Mi A1 stock) |

## Build

Satu perintah, tanpa compiler, tanpa `mkbootimg`, tanpa `dtc`:

```bat
make-tissot.bat
```

Atau dari Linux/macOS/WSL:

```bash
make tissot
# atau
./devices/tissot/build-bootimage.sh
```

### Artefak yang dihasilkan

| File | Isi |
|------|-----|
| `prebuilt/tissot-kernel-arm64.Image` | Kernel ARM64 (header `ARM\x64`) — **placeholder** |
| `prebuilt/tissot.dtb` | Device tree MSM8953 (FDT valid, 21 node) |
| `prebuilt/tissot.dts` | Versi teks DTB untuk dibaca manusia |
| `prebuilt/tissot-ramdisk.cpio.gz` | Ramdisk minimal (cpio newc + gzip) |
| `prebuilt/tissot-boot.img` | **Android boot image siap flash** |

### Flash ke Mi A1

Bootloader harus **ter-unlock** dulu.

```bash
fastboot devices
fastboot boot  prebuilt/tissot-boot.img     # coba tanpa menulis apa pun
fastboot flash boot prebuilt/tissot-boot.img  # kalau sudah yakin
```

> Selalu simpan `stock-boot.img` hasil dump sebelum `flash boot`, supaya bisa
> balik: `fastboot flash boot stock-boot.img`.

## Nilai hardware terverifikasi

Diambil dari device tree & kernel asli tissot — **bukan tebakan**:

| Item | Nilai | Sumber |
|------|-------|--------|
| `qcom,msm-id` | `<293 0>` = `<0x125 0>` | MSM8953 |
| `qcom,board-id` | `<0x1000b 0>` | `msm8953-qrd-sku3-tissot.dts` |
| Kernel base | `0x80000000` | LineageOS `BoardConfig.mk` |
| Page size | `2048` | idem |
| ramdisk offset | `0x01000000` → `0x81000000` | idem |
| tags offset | `0x00000100` → `0x80000100` | idem |
| Format kernel | **`Image.gz-dtb`** (gzip + DTB di-append) | idem |
| Boot partition | 64 MiB (`0x4000000`) | idem |
| Console UART | **`0x78AF000`** (ttyHSL0, `115200,n8`) | stock boot.img cmdline |
| eMMC | `sdhci@7824900` (reg `0x7824900`/`0x7824000`) | msm8953.dtsi + stock DTB |
| SD card | `sdhci@7864900` (reg `0x7864900`/`0x7864000`) | idem |
| Touch bus | **`i2c@78b7000`** (BLSP1 QUP3, irq 97) | stock DTB |
| Touch | **FocalTech FT5435** @ `0x38` | stock DTB (`focaltech@38`) |
| Panel | ft8716 / ili7807 / otm1911 (FHD video) | stock DTB |
| Boot header (stock) | **v1**, page 2048 | stock boot.img |
| Kernel stock | `Image.gz-dtb`, 9.863.568 B (gz 23,3 MB → Image) | idem |

> DTB referensi asli tersimpan di `devices/tissot/dt/stock.dtb` (269.951 B,
> **1304 node**) dan `stock-boot.img` (16,4 MB) — hasil ekstrak dari firmware
> stock `V10.0.24.0.PDHMIXM`. DTB kita (23 node) adalah subset untuk referensi
> driver; 5 node kuncinya sudah diverifikasi cocok dengan stock.

Referensi repo:
`LineageOS/android_device_xiaomi_tissot`,
`tissot-dev/android_device_xiaomi_tissot`,
`LineageOS/android_kernel_xiaomi_msm8953`.

## Status

**Pipeline build: jadi dan terverifikasi.** Boot image yang dihasilkan adalah
Android boot image yang valid secara struktur (header v0, page 2048, SHA-1 id,
kernel `ARM\x64`, FDT, ramdisk gzip) — bisa diterima `fastboot`.

> ⚠️ Ini **bukan** jalur ios-sweet. XNU memakai **ADT** (Apple Device Tree),
> bukan FDT Linux, dan ios-sweet menaruh **SHIM** bare-metal antara ABL dan XNU.
> Baca [`docs/GAP-VS-IOS-SWEET.md`](../../docs/GAP-VS-IOS-SWEET.md) sebelum
> menganggap ini bisa boot iOS.

**Kernel: masih placeholder.** Kernel di dalamnya adalah `wfi; b .` (spin loop),
bukan XNU. Untuk XNU ARM64 asli butuh cctools + macOS SDK.

**Yang masih butuh perangkat fisik:**
1. Unlock bootloader Mi A1 (menghapus data).
2. Build XNU ARM64 asli, taruh di `prebuilt/tissot-kernel-arm64.Image`
   lalu jalankan ulang packer.
3. Bring-up driver MSM8953 (UART dulu, lalu display/touch).
4. Root iOS (`ios15-root.simg`) via `mkiosroot.sh` dari ios-sweet.

Lihat `docs/PORT-TISSOT.md` untuk langkah lengkap dan **risiko ARMv8.0 §6**.
