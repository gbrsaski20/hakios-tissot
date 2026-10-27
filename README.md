# HakiOS — Xiaomi Mi A1 (`tissot`)

**Menjalankan XNU (kernel Darwin/iOS) secara native di Xiaomi Mi A1 — ARM64, bukan emulasi.**

Port ini membangun XNU dari source Apple (`xnu-8020`, generasi iOS 15) lalu
mem-boot-nya di SoC Qualcomm MSM8953 milik Mi A1, dengan user space iOS 15
sebagai root.

> ⚠️ **Repo ini punya dua jalur.** Yang **aktif** adalah **Mi A1 (ARM64)**.
> Jalur **x86_64** di bagian bawah adalah fase pertama proyek dan **tidak
> dipakai** untuk Mi A1 — lihat [Jalur lama](#jalur-lama-x86_64-fase-1-tidak-dipakai-untuk-mi-a1).

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

## Status

| Komponen | Status |
|----------|--------|
| Source `xnu-8020.140.41` + board config `TISSOT` | ✅ |
| Patch UART console (draft) | ✅ apply teruji, compile TBD |
| Apple Device Tree (`mkadt.py`) | ✅ round-trip byte-identik |
| Boot image Android (v0, `Image.gz-dtb`) | ✅ valid & self-verifying |
| Build kernel di CI (macOS runner) | ⏳ sedang berjalan |
| `mkpayload.py`, `shim/`, `mkiosroot.sh` | ❌ belum |
| Boot ke SpringBoard | ❌ target akhir |

## Berkas yang relevan untuk Mi A1

| Berkas | Fungsi |
|--------|--------|
| `tools/mkadt.py` | Editor/generator **Apple Device Tree** (format yang dipakai XNU) |
| `tools/extract_adt.py` | Ambil `DeviceTree.d22ap.im4p` dari IPSW + decompress |
| `tools/build_tissot_dtb.py` | FDT Linux MSM8953 (referensi alamat register) |
| `tools/make_tissot_bootimg.py` | Packer Android `boot.img` (kernel + ramdisk + DTB) |
| `tools/build_kernel_placeholder_arm64.py` | Kernel ARM64 placeholder (uji pipeline) |
| `devices/tissot/` | Profil device + `build-bootimage.sh` |
| `xnu/patches-8020/` | Patch series untuk XNU 8020 |
| `xnu/apply-8020.sh` | Unduh source + apply patch |
| `xnu-build-arm64.sh` | Build driver (`--check`, `--print`, `--force`) |
| `.github/workflows/xnu-tissot.yml` | CI build di macOS runner |
| `xnu8020-prep.bat`, `make-tissot.bat` | Launcher Windows |
| `docs/INSTALL-STEP-BY-STEP.md` | **Panduan lengkap A–H** |
| `docs/XNU8020-PORT-PLAN.md` | Rencana port berbasis `file:line` |
| `docs/GAP-VS-IOS-SWEET.md` | Perbandingan dengan panduan ios-sweet |

## Alur build

```
GitHub Actions (macOS)                     PC kamu (Windows)
─────────────────────                      ─────────────────
xnu/apply-8020.sh  → patch XNU              xnu8020-prep.bat
xnu-build-arm64.sh → kernel ARM64           tools/mkadt.py
        ↓                                        ↓
artifact: kernel.*                        tissot.adt + boot.img
        └───────────────┬────────────────────────┘
                        ↓
               fastboot boot  (kamu, di HP)
```

Perintah build yang dipakai CI:

```
make ARCH_CONFIGS=ARM64 KERNEL_CONFIGS=DEVELOPMENT \
     CURRENT_MACHINE_CONFIG=TISSOT SDKROOT=iphoneos
```

Mulai dari `docs/INSTALL-STEP-BY-STEP.md`.

---

## Jalur lama: x86_64 (fase 1, tidak dipakai untuk Mi A1)

Fase pertama proyek ini menargetkan **PC x86_64 / QEMU q35** — "Bliss OS tapi
untuk XNU". Hasilnya masih ada di repo dan masih bisa dibangun, tetapi **tidak
berhubungan dengan Mi A1** dan tidak dipakai oleh workflow `xnu-tissot`.

| Berkas | Fungsi |
|--------|--------|
| `xnu/hakios-x86.patch`, `xnu/files/`, `xnu/apply.sh` | Patch XNU + driver x86 (VGA, PS/2, AHCI, E1000, HDA, HPET) |
| `xnu-build-x86.sh`, `xnu-deps/` | Build kernel x86 |
| `xnuloader/` | Boot loader UEFI x86_64 |
| `userland/`, `sysimage/`, `qemu/`, `devices/pc-q35/` | User space, fetch IPSW, QEMU |
| `tools/make-esp.sh`, `make-boot-usb.sh`, `make-rufus-img.sh` | Image USB x86 |
| `tools/build_kernel_placeholder.py`, `make_rufus_img.py` | Placeholder x86 |
| `build-windows.ps1` / `.bat`, `make-bootable.bat`, `make-rufus-img.bat`, `run-qemu-windows.bat`, `setup-wsl.bat` | Launcher x86 |
| `README-windows.md` | Dokumentasi x86 |
| Target Makefile `x86-open`, `x86-full`, `qemu-open`, `qemu` | Build x86 |

Kenapa masih ada: bukan sampah — ia mendokumentasikan fase 1 dan masih bisa
dijalankan. Kalau tidak diperlukan lagi, jalur ini bisa dipindah ke
`legacy-x86/` atau dihapus.

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
