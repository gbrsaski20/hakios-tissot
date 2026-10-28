# HakiOS — Xiaomi Mi A1 (`tissot`)

**Menjalankan XNU (kernel Darwin/iOS) secara native di Xiaomi Mi A1 — ARM64, bukan emulasi.**

Port ini membangun XNU dari source Apple (`xnu-8020`, generasi iOS 15) lalu
mem-boot-nya di SoC Qualcomm MSM8953 milik Mi A1, dengan user space iOS 15
sebagai root.

> Repo ini **hanya** menargetkan Mi A1. Tidak ada jalur x86_64 di sini.

---

## Target perangkat

| Item | Nilai |
|------|-------|
| Device | Xiaomi Mi A1 (Android One), codename **`tissot`** |
| SoC | Qualcomm **MSM8953** (Snapdragon 625) |
| CPU | 8× Cortex-A53, **ARMv8.0-A**, tanpa PAC |
| RAM | 4 GB |
| Bootloader | harus **unlocked** |
| Identitas yang dipakai | iPhone X (`d22ap`) — dibutuhkan MobileGestalt |

## Kenapa iOS 15, bukan iOS 16

Apple mengirim satu keluarga binary `arm64` per versi iOS yang harus boot di
perangkat arm64 **tertua** yang didukung versi itu:

| iOS | Perangkat arm64 tertua | Level ARM |
|-----|------------------------|-----------|
| **15** | iPhone 6s (A9) | **ARMv8.0** ✅ cocok dengan A53 |
| 16 | iPhone 8 / X (A11) | ARMv8.2 — boleh pakai instruksi yang fault di A53 |

iOS 16 membuang A9, sehingga bebas memakai instruksi ARMv8.1/8.2. Karena itu
basis port ini **iOS 15.6.1 (19G82)**. Detail: `docs/IOS15-VS-IOS16-ARMv8.md`.

## Soal macOS — itu mesin build, bukan target

Kalau kamu lihat "butuh macOS" di dokumentasi, itu **bukan** berarti targetnya
macOS. Targetnya tetap Mi A1 (ARM64 Android).

XNU adalah kernel Apple. Build system-nya butuh **clang + cctools** (`ld` yang
paham Mach-O, `ctf_insert`, `kextsymboltool`) **+ SDK Apple**, dan makefile-nya
berasumsi userland BSD/macOS. Itu persyaratan **host**, dan tidak berubah
berapa pun targetnya. Proyek pembanding `dipa-studio/ios-sweet` juga membangun
kernelnya di GitHub Actions runner **macOS**.

Yang penting: **kamu tidak perlu punya Mac.** Repo publik dapat menit macOS
gratis di GitHub Actions — `.github/workflows/xnu-tissot.yml` melakukannya
otomatis. Di PC Windows kamu hanya menjalankan Python (rakit ADT + boot image).

## Status

| Komponen | Status |
|----------|--------|
| Source `xnu-8020.140.41` + board config `TISSOT` (patch 0001) | ✅ apply teruji |
| Driver UART console `ttyHSL0` (patch 0002) | ✅ apply teruji, compile TBD |
| Driver **GICv2 GIC-400** + ack/EOI MMIO (patch 0003) | ✅ apply teruji, compile TBD |
| `availability.pl` dari SDK host (patch 0004) | ✅ apply teruji, lolos tahap `do_build_setup` |
| Apple Device Tree (`mkadt.py`) | ✅ round-trip byte-identik, audit 12/12 |
| Boot image Android (v0, `Image.gz-dtb` + ADT ter-embed) | ✅ valid & self-verifying |
| Build kernel di CI (macOS runner) | ⏳ workflow siap (3 job), belum pernah jalan |
| `shim/`, `mkpayload.py` | ❌ belum — **pekerjaan terbesar berikutnya** |
| `mkiosroot.sh` (root iOS 15.6.1) | ❌ belum |
| Boot ke SpringBoard | ❌ target akhir |

## Berkas

| Berkas | Fungsi |
|--------|--------|
| `tools/mkadt.py` | Editor/generator **Apple Device Tree** (format yang dipakai XNU) + audit syarat XNU |
| `tools/extract_adt.py` | Ambil `DeviceTree.d22ap.im4p` dari IPSW + decompress |
| `tools/build_tissot_dtb.py` | FDT Linux MSM8953 (referensi alamat register) |
| `tools/make_tissot_bootimg.py` | Packer Android `boot.img` (kernel + ramdisk + DTB + ADT) |
| `tools/wsl-build.sh` | Seluruh pipeline dari WSL/Linux dalam satu perintah (patch + ABI + ADT/DTB + boot image; kompilasi kalau toolchain Mach-O ada) |
| `tools/wsl-check.sh` | Reproduksi job `patches` CI secara lokal di WSL/Linux (patch + penanda + image) |
| `tools/build_kernel_placeholder_arm64.py` | Kernel ARM64 placeholder (uji pipeline) |
| `devices/tissot/` | Profil device + `build-bootimage.sh` |
| `xnu/patches-8020/` | Patch series 0001–0009 untuk XNU 8020 |
| `xnu/apply-8020.sh` | Unduh source + apply patch + sanity check |
| `xnu-build-arm64.sh` | Build driver (`--check`, `--print`, `--force`, `--no-werror`, `--keep-going`) |
| `.github/workflows/xnu-tissot.yml` | CI: verifikasi patch → build kernel → rakit boot image |
| `Makefile` | `make adt` / `make check` / `make tissot` |
| `xnu8020-prep.bat`, `make-tissot.bat` | Launcher Windows |
| `docs/INSTALL-STEP-BY-STEP.md` | **Panduan lengkap A–H** |
| `docs/XNU8020-PORT-PLAN.md` | Rencana port berbasis `file:line` |
| `docs/GAP-VS-IOS-SWEET.md` | Perbandingan dengan panduan ios-sweet |

## Alur build

```
GitHub Actions                                        PC kamu (Windows)
──────────────────────────────────────────            ─────────────────
job patches   (ubuntu)  patch 0001..0009 + audit      xnu8020-prep.bat
job kernel    (macos)   make ... ARM64 TISSOT         make-tissot.bat
job package   (ubuntu)  rakit boot image                        ↓
        ↓                                                     ↓
artifact: xnu-tissot-kernel  (mach.* TISSOT)          tissot.adt
artifact: tissot-boot        (boot.img siap flash)     tissot-boot.img
        └──────────────────────┬──────────────────────────────┘
                               ↓
                      fastboot boot  (kamu, di HP)
```

Perintah build yang dipakai CI (sama dengan `make xnu8020` lokal di macOS):

```
make -C xnu-src-8020 -j4 \
     ARCH_CONFIGS=ARM64 KERNEL_CONFIGS=DEVELOPMENT \
     CURRENT_MACHINE_CONFIG=TISSOT SDKROOT=iphoneos
```

### Menjalankan build kernel di GitHub Actions

Tidak perlu Mac, tidak perlu install apa pun di PC:

1. Push repo ke GitHub (repo **publik** dapat menit macOS gratis; repo privat
   memakai kuota menit akun).
2. Buka tab **Actions** → pilih workflow **xnu-tissot**.
3. Klik **Run workflow**, pilih `config` (`DEVELOPMENT` / `RELEASE` / `DEBUG`),
   biarkan `pack` = true, lalu **Run workflow**.
4. Tunggu. Job `patches` selesai ~2 menit, `kernel` ~20–40 menit.
5. Unduh artefak di halaman run:
   - `xnu-tissot-kernel` — kernel XNU hasil build (Mach-O ARM64)
   - `tissot-boot` — `tissot-boot.img` hasil rakit, siap `fastboot`
   - `build-log` — log lengkap; 40 baris `error:` pertama sudah dicetak di
     ringkasan job

Kalau job `kernel` merah, **baca artefak `build-log`**, bukan hanya ringkasan:
error pertama biasanya soal knob `TISSOT.h`/`board_config.h` yang belum lengkap,
atau warning clang baru yang dipromosikan `-Werror`. Workflow otomatis
mengulang sekali dengan `WERROR=` kalau itu penyebabnya, supaya error aslinya
kelihatan.

> Catatan jujur: kernel hasil build masih **Mach-O**. ABL melompat ke offset 0
> payload, dan header Mach-O bukan kode — jadi `fastboot boot` belum akan
> sampai ke kernel. Yang memotong jarak itu adalah **SHIM** (lihat status di
> atas). Sampai SHIM ada, CI tetap berguna: ia membuktikan XNU bisa
> dikompilasi untuk TISSOT, dan itu gerbang utama sebelum bicara booting.

Mulai dari `docs/INSTALL-STEP-BY-STEP.md`.

---

## Independent, and Apple-free at the core

Proyek riset independen. **Tidak berafiliasi dengan atau didukung Apple.**
"iOS", "iPhone", "XNU", "Apple" hanya disebut untuk menjelaskan apa yang
dikerjakan kode ini.

Tidak ada berkas milik Apple di repo ini, dan tidak akan pernah:

- tidak ada IPSW, image iOS, dyld cache, font, atau aset Apple
- tidak ada key, sertifikat, atau activation
- `xnu-src-8020/` (source Apple) diunduh saat build, **tidak** di-commit
- ADT/DTB hasil ekstraksi dari IPSW juga di-*gitignore*

IPSW yang dipakai adalah milikmu sendiri (dari Apple CDN) dan tidak
didistribusikan ulang.

## Licenses

Kode saya mengikuti lisensi berkas yang diubah: patch XNU di bawah **Apple
Public Source License 2.0** (Apple menerbitkan XNU dengan lisensi itu; syaratnya
dipenuhi — perubahan dipublikasikan sebagai source dan notices dipertahankan),
sisanya sesuai header masing-masing berkas. iOS, image-nya, dan merek dagang
Apple milik pemiliknya, tidak ada di repo ini dan tidak didistribusikan.

Lihat `LEGAL.md`, `COMPLIANCE.md`, `THIRD_PARTY_LICENSES.md`, dan `NOTICE`.
Semua ini bukan nasihat hukum.
