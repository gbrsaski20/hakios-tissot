# Gap analysis: proyek ini vs panduan ios-sweet

Dokumen ini menjawab satu pertanyaan: **apakah pekerjaan kita sudah sesuai
panduan `dipa-studio/ios-sweet` "How to do it yourself"?**

Jawaban singkat: **belum.** Kita baru mengerjakan lapisan *packing image*, dan
bahkan format yang dipakai berbeda. Dokumen ini memetakan persis apa yang sudah
ada, apa yang belum, dan mana yang benar-benar menghalangi.

---

## 1. Verifikasi IPSW (sudah dilakukan)

IPSW: `iPhone10,3,iPhone10,6_15.6.1_19G82_Restore.ipsw`

| Item | Hasil |
|------|-------|
| Ukuran | 5,75 GiB |
| Jumlah entry | 91 |
| Build | **15.6.1 / 19G82** — sengaja beda dari ios-sweet (mereka 16.7.16); alasan di `docs/IOS15-VS-IOS16-ARMv8.md` |
| Device tree | `Firmware/all_flash/DeviceTree.d22ap.im4p` (33.719 B) ✅ |
| Device tree lain | `Firmware/all_flash/DeviceTree.d221ap.im4p` (varian iPhone 8 Plus) |
| IM4P type | `dtre`, desc `EmbeddedDeviceTrees-7153.140.37.700.2` |
| Payload DT | 33.650 B, **LZFSE** (magic `bvx2`) |
| Kernel | `kernelcache.release.iphone10b` (18.204.358 B) |

Catatan: entry `.im4p` di dalam IPSW adalah **IMG4 (DER)**, bukan IM4P biner:

```
SEQ { IA5 "IM4P", IA5 "dtre", IA5 "<desc>", OCT <payload>, SEQ{INT,INT} }
```

Ekstraksi ulang kapan saja dengan:

```bash
python tools/extract_adt.py "F:\SETUP\iPhone10,3,iPhone10,6_15.6.1_19G82_Restore.ipsw"
```

Payload masih LZFSE; untuk men-decompress pakai `pip install lzfse` (script
melakukannya otomatis) atau `ipsw img4 im4p extract`.

---

## 2. Apa yang sebenarnya dilakukan ios-sweet

| Step | Isi | Tool |
|------|-----|------|
| 0 | Backup partisi + unpack stock `boot.img` → DTB stock | `tools/unpack_bootv2.py` |
| 1 | **Build XNU dari source** (`xnu-8796` + patch) di **GitHub macOS runner** | `gh workflow run xnu.yml`, `blacktop/darwin-xnu-build` |
| 2 | Rakit root iOS dari IPSW: OS.dmg + SystemOS.dmg + AppOS.dmg → HFS+ → sparse | `mkiosroot.sh`, `sweet-root-tweaks.py`, `img2simg` |
| 2b | Ambil `DeviceTree.d22ap.im4p` → **ADT** | `remotezip.py` + `ipsw` |
| 3a | Generate **ADT** (Apple Device Tree) dari layout MMIO target + identitas iPhone X | `tools/mkadt.py` |
| 3b | Pack kernel + ADT + boot-args → payload | `tools/mkpayload.py` |
| 3c | Build **SHIM** (bare-metal C+asm) → `boot.img` **v2** | `shim/build.sh`, `aarch64-linux-gnu-gcc`, `mkbootimg` |
| 4 | `fastboot flash userdata` + `fastboot boot` | fastboot |
| 5 | Ambil kernel log via recovery | `sweet-log-pull.sh`, `sweet-crash.py` |

Boot-args mereka (contoh asli, gaya XNU — bukan gaya Android):

```
debug=0xc serial=3 cpus=6 keepsyms=1 -enable_kprintf_spam -noprogress
rd=ufsroot0 ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1
sweetfb_noconsole=1 sweetfb_hz=30
```

---

## 3. Perbandingan dengan kondisi proyek ini

| Komponen | ios-sweet | Proyek ini | Status |
|----------|-----------|------------|--------|
| Kernel | XNU hasil build source, `kernel.development.sweet` | placeholder `wfi; b .` | ❌ |
| Device tree untuk XNU | **ADT** (Apple), dibuat `mkadt.py` | **FDT Linux** (`tissot.dtb`) | ❌ format beda |
| Perantara ABL→XNU | **SHIM** bare-metal C+asm | tidak ada (lompat langsung) | ❌ kritis |
| Format boot image | Android boot **v2** | Android boot **v0** | ⚠️ beda |
| Boot-args | XNU (`rd=ufsroot0`, `debug=0xc`, …) | Android (`androidboot.*`) | ⚠️ beda |
| Root iOS | HFS+ dari 3 dmg IPSW → `userdata` | ramdisk 311 B placeholder | ❌ |
| Unpack stock boot.img | `unpack_bootv2.py` | tidak ada | ❌ |
| Build toolchain | `aarch64-linux-gnu-gcc`, `mkbootimg` | Python murni (tanpa compiler) | ⚠️ |
| Log / symbolication | `sweet-log-pull.sh`, `sweet-crash.py` | tidak ada | ❌ |
| Ambil DeviceTree dari IPSW | `remotezip.py` + `ipsw` | `tools/extract_adt.py` | ✅ (ekstrak; decompress perlu lzfse) |

---

## 4. Tiga perbedaan yang benar-benar menghalangi

### 4.1 XNU tidak memakai FDT Linux — ia memakai ADT

`tissot.dtb` yang kita generate adalah **Flattened Device Tree** (magic
`0xd00dfeed`), format Linux/U-Boot. XNU **tidak** mem-parse FDT. ios-sweet
membangun **Apple Device Tree** lewat `mkadt.py` dari layout MMIO SoC target +
identitas iPhone X (`--highmem`).

Konsekuensi: `tissot.dtb` **tidak bisa** dipakai untuk boot XNU. Nilainya hanya
sebagai **referensi alamat register MSM8953** saat menulis driver.

### 4.2 Ada SHIM di antara bootloader dan XNU

ABL Qualcomm tidak "melompat ke XNU" begitu saja. ios-sweet punya `shim/`
(bare-metal C + asm) yang: menyiapkan MMIO/clock minimal, menaruh ADT di
alamat yang XNU harapkan, meneruskan boot-args, baru melompat ke XNU.
Tanpa komponen ini, image tidak akan pernah sampai ke kode XNU.

### 4.3 Kernel harus XNU hasil build source

ios-sweet **tidak** memakai `kernelcache` dari IPSW. Mereka build `xnu-8796`
(Apple open source) + `xnu/patches/` di GitHub macOS runner. `kernelcache`
IPSW berguna sebagai referensi, tapi ia tersegel IM4M dan tidak dimaksudkan
untuk boot di luar Apple.

---

## 5. Jadi artefak kita sekarang berguna untuk apa?

| Artefak | Nilai |
|---------|-------|
| `prebuilt/tissot-boot.img` | Bukti pipeline packing Android boot image v0 benar (header, SHA-1, page map). Bisa jadi dasar kalau nanti pindah ke v2. |
| `tools/make_tissot_bootimg.py` | Packer boot image murni Python — bisa diadaptasi ke v2 (dibutuhkan shim). |
| `prebuilt/tissot.dtb` | **Referensi alamat MMIO MSM8953** (UART/I2C/eMMC/GIC/timer) untuk `mkadt.py` dan driver. |
| `tools/build_tissot_dtb.py` | Generator FDT murni Python (berguna untuk target Linux, bukan XNU). |
| `tools/extract_adt.py` | Langkah 2b panduan: ambil DeviceTree dari IPSW tanpa download ulang. |
| `make-tissot.bat` | Satu klik build artefak di atas. |

**Yang belum ada sama sekali:** build XNU ARM64, `mkadt.py`, `shim/`,
`mkiosroot.sh`, `mkpayload.py`, `unpack_bootv2.py`, tool log.

---

## 6. Risiko yang belum hilang (dan makin penting)

ios-sweet menargetkan **SM7150** (Cortex-A55, ARMv8.2). Semua port iOS 16 yang
terkonfirmasi berjalan ada di kelas **ARMv8.2**.

Mi A1 = **MSM8953 / Cortex-A53 = ARMv8.0**. Jika kernel/dyld iOS 16 memakai
instruksi ARMv8.1/8.2 (atomics LSE, FP16, …), kernel akan fault di A53 dan
port ini tidak akan pernah boot. **Ini harus diverifikasi lebih dulu** sebelum
investasi besar.

> ✅ **Sudah ada jalan keluarnya: pindah ke iOS 15.** iOS 15 masih mendukung
> iPhone 6s (A9, **ARMv8.0**), sehingga seluruh userland `arm64`-nya wajib
> kompatibel ARMv8.0. iOS 16 membuang A9 → minimum A11 (ARMv8.2), itulah
> sumber risikonya. Analisis + URL IPSW: **[`IOS15-VS-IOS16-ARMv8.md`](IOS15-VS-IOS16-ARMv8.md)**.

---

## 7. Dua jalur realistis

### Jalur A — ikut ios-sweet apa adanya (paling benar, pekerjaan besar)

1. Fork `dipa-studio/ios-sweet`.
2. Build XNU via GitHub Actions macOS runner (`gh workflow run xnu.yml`).
3. Adaptasi `tools/mkadt.py` → layout MMIO **MSM8953** (pakai `tissot.dtb` kita
   sebagai sumber alamat) + identitas iPhone X.
4. Adaptasi `shim/` → tissot (UART `0x078b0000`, dll).
5. `mkiosroot.sh` untuk root iOS dari IPSW yang sudah kamu punya.
6. `fastboot boot` lalu baca log, iterasi.

### Jalur B — verifikasi kelayakan dulu (murah, menyelamatkan waktu)

1. Decompress `kernelcache.release.iphone10b` dari IPSW.
2. Scan instruksi ARMv8.1/8.2 (LSE atomics `0x08xxxxxx`/`0xC8xxxxxx`, FP16) di
   jalur boot kritis.
3. Kalau ditemukan di jalur yang pasti dieksekusi → **stop**, port ke ARMv8.0
   tidak realistis.
4. Kalau aman → lanjut Jalur A dengan keyakinan.

---

## 8. Checklist

- [x] IPSW iPhone X 15.6.1 (19G82) tersedia & terverifikasi
- [x] DeviceTree `d22ap.im4p` berhasil diekstrak dari IPSW
- [x] Nilai hardware asli tissot (board-id, UART console, touch, base/pagesize,
      format kernel `Image.gz-dtb`) diambil dari device tree LineageOS
- [ ] Payload ADT di-decompress (`pip install lzfse` atau `ipsw img4 im4p extract`)
- [ ] `unpack_bootv2.py` → DTB stock tissot (untuk perbandingan alamat)
- [ ] Build XNU ARM64 (GitHub macOS CI)
- [ ] `mkadt.py` untuk MSM8953
- [ ] `shim/` untuk tissot
- [ ] Root iOS HFS+ (`mkiosroot.sh`) → flash `userdata`
- [ ] Verifikasi risiko ARMv8.0 (Jalur B)
- [ ] Boot pertama + baca kernel log
