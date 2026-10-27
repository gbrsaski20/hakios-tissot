# Port iOS ke Xiaomi Mi A1 (codename: tissot)

Panduan ini mencatat upaya memport iOS ke **Xiaomi Mi A1** melalui jalur
**ios-sweet** — yaitu menjalankan XNU + user space iOS **native** di atas SoC
ARM64 (bukan emulasi). Basis yang dipakai **iOS 15.6.1 (19G82)**, bukan iOS 16,
karena userland `arm64` iOS 15 masih harus jalan di A9 (ARMv8.0) sehingga cocok
untuk Cortex-A53; lihat `docs/IOS15-VS-IOS16-ARMv8.md`.

> **Status (diperbarui):** **Pipeline build sudah jadi & terverifikasi.**
> `make-tissot.bat` / `make tissot` menghasilkan `prebuilt/tissot-boot.img` —
> Android boot image **valid** (header v0, page 2048, SHA-1 id, kernel ARM64
> dengan magic `ARM\x64`, FDT `0xd00dfeed`, ramdisk gzip). Semua dibuat murni
> dengan Python, **tanpa** compiler / `mkbootimg` / `dtc`.
>
> Yang **belum**: kernel di dalamnya masih *placeholder* (`wfi; b .`), bukan
> XNU. Boot ke iOS sungguhan tetap butuh: XNU ARM64 asli (cctools + macOS SDK),
> bootloader Mi A1 ter-unlock, root iOS, dan bring-up driver MSM8953. Lihat §6.
>
> ⚠️ **Penting:** pipeline packing di atas **bukan** jalur ios-sweet. XNU tidak
> memakai FDT Linux (ia memakai **ADT**), dan ios-sweet menaruh **SHIM**
> bare-metal antara ABL dan XNU. Perbandingan lengkap + apa yang masih kurang:
> **[`docs/GAP-VS-IOS-SWEET.md`](GAP-VS-IOS-SWEET.md)**.

---

## 1. Mengapa tissot

| Properti | Nilai |
|----------|-------|
| Device | Xiaomi Mi A1 (Android One), codename `tissot` |
| SoC | Qualcomm **MSM8953** (Snapdragon 625) |
| CPU | 8× Cortex‑A53, **ARMv8.0‑A** (64‑bit) |
| RAM | 4 GB |
| Bootloader | Unlockable via Xiaomi Mi Unlock (ada masa tunggu) |
| Rilis | 2017 |

Keuntungan: ARM‑on‑ARM → iOS ARM64 jalan native (cepat). Cortex‑A53 **tidak
punya PAC** (Pointer Authentication) — sama seperti iPhone X, jadi "gate" PAC
yang dibicarakan ios‑sweet sudah terpenuhi.

---

## 2. Prasyarat

- **Mi A1 fisik** dengan bootloader **ter-unlock** (proses Mi Unlock menghapus
  semua data — backup dulu).
- PC dengan `adb` + `fastboot` (platform‑tools).
- **iOS 15.6.1 (19G82) IPSW iPhone X (iPhone10,3 / `d22ap`)** — dari punyamu sendiri
  (Apple CDN / ipsw.me). Tidak didistribusikan.
- Referensi kode: `dipa-studio/ios-sweet` dan port turunannya (`ios-topaz` /
  `UniXNU`). Pelajari tools mereka — `devices/tissot/` di sini meniru polanya.
- Opsi: tool `remotezip.py` (ambil 1 file dari IPSW tanpa download utuh) dan
  `mkiosroot.sh` (rakit root iOS) dari ios‑sweet.

---

## 3. Cara kerja ios‑sweet (disingkat)

1. Build **XNU boot image** untuk perangkat (kernel XNU + device tree).
2. XNU diberi **device tree palsu dari iPhone X (`d22ap`)** supaya mengira ia
   boot di iPhone. Inilah kunci trik ini.
3. **Driver per‑device** ditulis untuk silikon asli (UART, display, touch, …)
   karena DT bilang "iPhone X" padahal hw-nya MSM8953.
4. iPhone X dipilih sebagai **model terakhir tanpa PAC**.

Port yang sudah ada: Snapdragon 685 (Redmi Note 12 4G / `ios-topaz`), 732G
(Redmi Note 10 Pro), 8 Gen 2 (Xiaomi Pad 6S Pro / `UniXNU`). **Semua SoC
terkonfirmasi itu ARMv8.2‑class.** tissot (ARMv8.0) lebih tua — lihat risiko §6.

---

## 4. Langkah port (rinci)

### 4.1 Unlock bootloader
```bash
# Di Windows/Linux, dengan Mi A1 terhubung + USB debugging on
fastboot oem unlock   # (atau token dari Mi Unlock; masa tunggu bisa hari)
# Perangkat ter-reset ke factory. Setup ulang, aktifkan USB debug lagi.
```
> Bootloader ter-unlock **menghapus data** dan bisa membatalkan garansi.

### 4.2 Siapkan iOS root (reuse step 2 dari ios‑sweet)
Gunakan `mkiosroot.sh` untuk merakit `ios15-root.img` dari IPSW iPhone X:
```bash
# (dari repo ios-sweet)
tools/mkiosroot.sh OS.dmg SystemOS.dmg AppOS.dmg ios15-root.img 16G
sudo fsck.hfsplus -fy ios15-root.img
# mount, jalankan sweet-root-tweaks.py, unmount, img2simg -> ios15-root.simg
```
Root ini **ARM64 native** → berlaku untuk tissot maupun device ARM lain.

### 4.3 Ambil device tree
- **DT palsu iPhone X**: ekstrak `DeviceTree.d22ap.im4p` dari IPSW (step 2):
  ```bash
  python3 tools/remotezip.py IPSW_URL DeviceTree.d22ap.im4p devices/tissot/dt
  ipsw img4 im4p extract devices/tissot/dt/DeviceTree.d22ap.im4p \
        -o devices/tissot/dt/d22ap.adt
  ```
- **DT asli tissot** (untuk inisialisasi hw sebelum XNU / referensi driver):
  lihat `devices/tissot/extract-dt.sh` (template; butuh URL firmware Mi A1).

### 4.4 Build boot image untuk tissot

**Sudah jadi** — pakai toolchain Python milik proyek ini (tidak butuh
`mkbootimg`, tidak butuh `dtc`, tidak butuh compiler):

```bat
make-tissot.bat
```

atau dari Linux/macOS/WSL:

```bash
make tissot
# atau langsung:
./devices/tissot/build-bootimage.sh
```

Tool yang dipanggil berurutan:

| Tool | Output |
|------|--------|
| `tools/build_kernel_placeholder_arm64.py` | `prebuilt/tissot-kernel-arm64.Image` |
| `tools/build_tissot_dtb.py` | `prebuilt/tissot.dtb` (+ `.dts`) |
| `tools/make_tissot_bootimg.py` | `prebuilt/tissot-ramdisk.cpio.gz`, `prebuilt/tissot-boot.img` |

Kalau sudah punya **XNU ARM64 asli**, tinggal lewatkan:

```bash
./devices/tissot/build-bootimage.sh \
    --kernel path/ke/xnu-arm64.Image \
    --ramdisk path/ke/ios15-root.simg \
    --dtb devices/tissot/dt/d22ap.dtb \
    --out devices/tissot/tissot-ios-boot.img
```

> Catatan ios-sweet: mereka memberi XNU **DT iPhone X (`d22ap`)** yang dipalsukan.
> Pakai `--dtb devices/tissot/dt/d22ap.dtb` untuk pola itu. DT bawaan yang
> di-generate (`tissot.dtb`) justru mendeskripsikan **MSM8953 asli** — berguna
> untuk referensi driver dan memahami hardware.

### 4.5 Boot
```bash
fastboot boot tissot-ios-boot.img     # coba boot tanpa flash dulu
# atau, kalau stabil: fastboot flash boot tissot-ios-boot.img
```

### 4.6 Driver bring‑up MSM8953
Ini bagian tersulit. Karena XNU "dibohongi" pakai DT iPhone X, kamu harus
memetakan/pasang driver XNU untuk periferal MSM8953 sungguhan:
- **UART (serial)** dulu — untuk lihat log boot XNU. Ini sudah dikerjakan:
  patch 0002 menambahkan driver `ttyHSL0` di `pexpert/arm/pe_serial.c`
  (lihat `xnu/patches-8020/0002-tissot-uart-console.patch`).
- **Interrupt controller** — patch 0003 menambahkan driver GICv2 (GIC-400)
  di `pexpert/arm/pe_fiq.c`. Tanpa itu kernel hang setelah beberapa baris UART.
- **Display** (panel Mi A1) + **touch** (synaptics/Goodix).
- Clock/reset, GPIO, regulator — biasanya lewat DT/ACPI mapping.
  Belum ada driver display/touch; itu pekerjaan setelah kernel bisa boot.

### 4.7 First boot & serial
Sambungkan serial/USB‑serial ke Mi A1, buka `screen`/`PuTTY` 115200 8N1, lalu
`fastboot boot`. Harapkan: log XNU mulai, mount root iOS, `launchd`, lalu
SpringBoard di layar.

---

## 5. Checklist

- [x] Toolchain Python: kernel ARM64 + DTB + boot.img (tanpa compiler)
- [x] `tissot-boot.img` valid & self-verifying (SHA-1, ARM\x64, FDT, gzip)
- [ ] Bootloader Mi A1 ter‑unlock (data sudah di‑backup)
- [x] IPSW iPhone X 16.7.16 (20H392) tersedia — disimpan sebagai referensi
- [ ] IPSW iPhone X **15.6.1 (19G82)** di‑download — basis port untuk ARMv8.0
      (lihat `IOS15-VS-IOS16-ARMv8.md`)
- [ ] `ios15-root.img` / `.simg` rakit via mkiosroot.sh
- [ ] `d22ap.dtb` diekstrak dari IPSW
- [ ] XNU ARM64 asli dibangun → ganti `tissot-kernel-arm64.Image`
- [ ] Driver UART MSM8953 jalan (serial log keluar)
- [ ] Driver display + touch tissot
- [ ] Boot ke SpringBoard (target akhir)

---

## 6. Risiko utama (baca sebelum buang waktu)

1. **ARMv8.0 vs ARMv8.2 (risiko yang sudah dimitigasi).** Port iOS 16 yang
   dikonfirmasi jalan semuanya di SoC **ARMv8.2-class** (SD685/7150/8 Gen 2),
   sedangkan MSM8953 Cortex-A53 adalah **ARMv8.0** (2017). XNU / dyld shared
   cache iOS 16 bisa memakai instruksi ARMv8.1/8.2 (atomics, FP16, ...) yang
   akan **illegal instruction / fault** di A53.

   > ✅ **Solusi: pakai iOS 15, bukan 16.** iOS 15 masih mendukung iPhone 6s
   > (A9 = **ARMv8.0**), jadi seluruh userland `arm64` iOS 15 wajib kompatibel
   > ARMv8.0. iOS 16 membuang A9 (minimum A11/ARMv8.2) — itu sumber risikonya.
   > Lihat **[`IOS15-VS-IOS16-ARMv8.md`](IOS15-VS-IOS16-ARMv8.md)** untuk bukti
   > (data ipsw.me) dan URL IPSW 15.6.1 (19G82) untuk d22ap.
2. **Driver bring‑up** per‑device untuk MSM8953 (display/touch/UART) — kerja
   rendah‑level.
3. **Bootloader / metode boot**: `fastboot boot` XNU mungkin butuh trik (hypervisor
   EL2 / chainload). Ikuti pola ios‑sweet persis.
4. **Wipe & garansi**: unlock menghapus data, bisa batalkan garansi.
5. **Legal**: hanya pakai IPSW punyamu sendiri; jangan distribusikan file iOS.

---

## 7. Referensi

- `dipa-studio/ios-sweet` — projet origin (Redmi Note 10 Pro, SD732G)
- `ios-topaz` — port ke Redmi Note 12 4G (SD685)
- `UniXNU` — port ke Xiaomi Pad 6S Pro (SD8 Gen 2, iPadOS)
- `devices/tissot/` — scaffold profile untuk device ini
- `docs/XNU8020-PORT-PLAN.md` — status & rencana port XNU 8020 ke tissot
- `docs/IOS15-VS-IOS16-ARMv8.md` — kenapa iOS 15, bukan 16
- `docs/INSTALL-STEP-BY-STEP.md` — panduan langkah demi langkah A–H
