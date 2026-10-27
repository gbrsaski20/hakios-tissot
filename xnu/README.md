# XNU untuk Xiaomi Mi A1 (`tissot`)

Direktori ini berisi **patch series** yang membuat XNU dari Apple bisa
dibangun dan boot di Qualcomm **MSM8953** (Snapdragon 625, 8× Cortex-A53,
ARMv8.0-A).

Basis: **`xnu-8020.140.41`** — generasi kernel iOS 15. Apple hanya
mempublikasikan tiga tag 8020: `.101.4` (iOS 15.0), `.121.3`, `.140.41`
(terbaru). iOS 15 dipilih karena userland `arm64`-nya masih harus jalan di
iPhone 6s (A9 = ARMv8.0), jadi tidak memakai instruksi ARMv8.2 yang akan
trap di Cortex-A53. Lihat `docs/IOS15-VS-IOS16-ARMv8.md`.

## Isi direktori

| File | Isi |
|------|-----|
| `apply-8020.sh` | Unduh `xnu-8020.140.41`, terapkan semua patch berurutan, lalu sanity-check penanda tiap patch |
| `patches-8020/0001-add-tissot-board-config.patch` | Board config `TISSOT`: masuk `SUPPORTED_ARM64_MACHINE_CONFIGS`, `-mcpu=cortex-a53`, **`arm64` bukan `arm64e`** (Cortex-A53 tidak punya PAC), `TISSOT.h`, blok `board_config.h` |
| `patches-8020/0002-tissot-uart-console.patch` | Driver console BLSP1 UART1 @ `0x078AF000` (`ttyHSL0`): `SERIAL_TISSOT_UART`, offset register UARTDM, blok driver di `pe_serial.c` |
| `patches-8020/0003-tissot-gicv2-interrupts.patch` | Driver **GIC-400 (GICv2)** + jalur ack/EOI MMIO. Tanpa ini `pe_init_fiq()` kosong dan kernel hang setelah beberapa baris UART |
| `patches-8020/0004-availability-pl-host-sdk.patch` | `bsd/sys/make_symbol_aliasing.sh`: `availability.pl` sudah **tidak ada di Xcode 26** (tidak di SDK iPhoneOS, tidak di SDK macOS, tidak di `/usr/local`). Patch ini mencari target SDK -> host SDK -> daftar versi bawaan, supaya build tidak mati di `_symbol_aliasing.h` |
| `patches-8020/0005-clang-modern-compat.patch` | Kompatibilitas clang Xcode 26: buang `-enable-trivial-auto-var-init-zero-...` (sudah dihapus dari clang, dan `-ftrivial-auto-var-init=zero` sudah ada di baris atasnya), jaga `-I$(SDKROOT)/usr/local/include/kernel` dengan `wildcard`, matikan `-Wmissing-include-dirs` |

## Kenapa lima patch itu perlu

**0001 — PAC.** `makedefs/MakeInc.def` memaksa `arm64e` untuk semua build
ARM64 kalau `EMBEDDED_DEVICE_MAP` tidak ada. `arm64e` = ABI dengan Pointer
Authentication, dan Cortex-A53 tidak punya PAC → kernel tidak akan jalan.
Patch ini mengembalikannya ke `arm64` khusus `CURRENT_MACHINE_CONFIG=TISSOT`.

**0002 — console.** Tanpa UART tidak ada cara melihat apa pun sebelum display
hidup. `init()` sengaja **tidak** memprogram ulang baud rate: ABL sudah
menyetel `console=ttyHSL0,115200,n8`, jadi driver hanya menyalakan
transmitter.

**0003 — interrupt.** XNU 8020 hanya punya **Apple AIC** dan **GICv3**
(`HAS_GIC_V3`, yang cuma didefinisikan `VMAPPLE.h`). MSM8953 memakai
**GIC-400 = GICv2**. Untuk build non-GICv3, `pe_init_fiq()` di source asli
kosong total, dan `sleh_irq()` memakai system register GICv3
(`ICC_IAR0_EL1`/`ICC_EOIR0_EL1`) yang tidak ada di GICv2. Akibatnya kernel
akan keluar beberapa baris lalu hang selamanya tanpa pernah menerima
interrupt timer.

**0004 — SDK target bukan SDK host.** Ini bukan soal tissot; build XNU
apa pun untuk **iPhoneOS** kena. `bsd/sys/make_symbol_aliasing.sh` menyusun
`${SDKROOT}/usr/local/libexec/availability.pl`, dan SDK iPhoneOS tidak
punya `usr/local/libexec` sama sekali:

```
$ ls "$(xcrun -sdk iphoneos -show-sdk-path)/usr/local/libexec"
ls: No such file or directory
```

Gejalanya menyesatkan — yang muncul cuma `make[5]: *** [_symbol_aliasing.h]
Error 1` lalu `Error 2` dua tingkat di atasnya. Patch ini memakai salinan
dari SDK macOS (skrip perl yang sama, mendukung `--ios` maupun `--macosx`),
dan tetap mengeluarkan error asli kalau dua-duanya tidak ada.

## Cara pakai

```bash
# unduh source + terapkan 0001, 0002, 0003
./xnu/apply-8020.sh

# verifikasi toolchain (akan melaporkan yang kurang)
./xnu-build-arm64.sh --check

# build (butuh macOS + cctools + SDK — lihat catatan di bawah)
./xnu-build-arm64.sh --config DEVELOPMENT --jobs 4
```

Di Windows, pakai `xnu8020-prep.bat` — itu menjalankan langkah pertama dan
kedua saja (source + patch), karena build kernelnya tidak bisa di Windows.

## Kenapa build butuh macOS

XNU butuh **clang + cctools** (`ld` dengan dukungan Mach-O, `ctf_insert`,
`kextsymboltool`) **+ SDK Apple**, dan makefile-nya berasumsi userland
BSD/macOS. Ini persyaratan **mesin build**, bukan target: targetnya tetap
Mi A1 (ARM64). Proyek pembanding `dipa-studio/ios-sweet` juga membangun
kernelnya di GitHub Actions runner macOS.

Karena repo publik dapat menit macOS gratis di GitHub Actions, jalur yang
dipakai adalah `.github/workflows/xnu-tissot.yml`.

Perintah `make` yang benar (terverifikasi di `makedefs/MakeInc.cmd:143-151`):

```
make ARCH_CONFIGS=ARM64 KERNEL_CONFIGS=DEVELOPMENT \
     CURRENT_MACHINE_CONFIG=TISSOT SDKROOT=iphoneos
```

`SDKROOT=iphoneos` dan **bukan** path SDK macOS: `PLATFORM` diturunkan dari
`xcrun -sdk $(SDKROOT) -show-sdk-platform-path`. Memberi SDK macOS membuat
`PLATFORM=MacOSX` → yang dibangun kernel ARM64-macOS, bukan iPhoneOS. Jangan
memberi `PLATFORM` manual — nilainya harus *undefined* agar derivasi itu jalan.

## Status

| Patch | Status |
|-------|--------|
| 0001 board config | ✅ apply teruji |
| 0002 UART console | ✅ apply teruji, **belum dikompilasi** |
| 0003 GICv2 | ✅ apply teruji, **belum dikompilasi** |

Rantai `pristine → 0001 → 0002 → 0003` terbukti mereproduksi tree kerja
byte-identik di 7 file. Detail lengkap dan sisa pekerjaan (SHIM, verifikasi
hardware): `docs/XNU8020-PORT-PLAN.md`.

## Lisensi

XNU adalah milik Apple, APSL 2.0. Patch di direktori ini adalah karya proyek
ini dan mengikuti APSL 2.0 untuk file yang merupakan turunan XNU. Lihat
`LEGAL.md` dan `THIRD_PARTY_LICENSES.md`.
