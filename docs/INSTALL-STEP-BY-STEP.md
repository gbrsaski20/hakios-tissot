# Panduan instalasi HakiOS / tissot — langkah demi langkah

Panduan ini menuntun dari **nol** sampai **boot pertama** (atau sampai titik
yang bisa dicapai saat ini).

Legenda status:

| Ikon | Arti |
|------|------|
| ✅ | Bisa dikerjakan **sekarang** dengan isi repo ini |
| ⏳ | Menunggu komponen yang **belum ditulis** (lihat `docs/XNU8020-PORT-PLAN.md`) |
| 🔒 | Butuh **perangkat fisik** / akun tertentu |

---

# Bagian A — Persiapan

## A1. Yang dibutuhkan ✅🔒

| Item | Keterangan |
|------|-----------|
| Xiaomi Mi A1 (`tissot`) | Bootloader harus **unlocked** |
| Kabel USB data | Bukan kabel charge-only |
| PC Windows | Sudah ada repo ini di `E:\workbuddyainew\2026-10-26-09-55-05` |
| `adb` + `fastboot` | Android platform-tools |
| Akun GitHub | Untuk build kernel (gratis) |
| IPSW iPhone X **15.6.1 (19G82)** | 5,38 GiB — sudah kamu download |

## A2. Install platform-tools ✅

1. Download: https://developer.android.com/tools/releases/platform-tools
2. Extract ke `C:\platform-tools`
3. Tambahkan ke PATH, atau selalu `cd C:\platform-tools` sebelum memakai `fastboot`.

Cek:

```bat
fastboot --version
adb --version
```

## A3. Unlock bootloader 🔒

> ⚠️ **Ini menghapus SELURUH data di HP.** Backup foto/dokumen dulu.

1. Di HP: **Setelan → Tentang ponsel** → tap **Nomor bentukan** 7× → Developer options aktif.
2. **Setelan → Sistem → Opsi developer** → aktifkan **USB debugging** dan **OEM unlocking**.
3. Di PC:

```bat
adb devices            REM harus muncul "device", bukan "unauthorized"
adb reboot bootloader
fastboot oem unlock    REM atau ikuti tool Mi Unlock (ada masa tunggu 7 hari)
```

4. Setelah reset, setup ulang HP, aktifkan **USB debugging** lagi.

Cek: `fastboot getvar unlocked` → harus `unlocked: yes`.

## A4. Backup boot stock — WAJIB sebelum flash apa pun ✅

Kamu sudah punya firmware stock di `F:\SETUP`:

```
tissot_images_V10.0.24.0.PDHMIXM_20200810.0000.00_9.0_49f16fd30d.tgz
```

`boot.img` sudah diekstrak ke:

```
devices\tissot\dt\stock-boot.img        (16,4 MB)
```

> **Penting:** pakai `boot.img` dari **versi firmware yang sama** dengan yang
> terpasang di HP. Kalau HP kamu beda versi, extract ulang dari tgz yang cocok.

Simpan juga salinan di tempat aman:

```bat
copy devices\tissot\dt\stock-boot.img D:\backup\tissot-stock-boot.img
```

## A5. Siapkan IPSW 15.6.1 ✅

File yang benar (dari link yang saya berikan):

```
iPhone10,3,iPhone10,6_15.6.1_19G82_Restore.ipsw
```

Pastikan **selesai 100%** (bukan `.fdmdownload`). Ukuran resmi:
**5.777.710.157 byte**. Cek:

```bat
powershell -c "(Get-Item 'F:\SETUP\iPhone10,3,iPhone10,6_15.6.1_19G82_Restore.ipsw').Length"
```

Kalau masih `.fdmdownload`, tunggu FDM selesai lalu rename jadi `.ipsw`.

---

# Bagian B — Siapkan source XNU + patch ✅

## B1. Jalankan persiapan (satu klik)

```bat
xnu8020-prep.bat
```

Yang terjadi:

1. Unduh `xnu-8020.140.41` (~14 MiB) → `xnu-src-8020\`
2. Terapkan `xnu\patches-8020\0001-add-tissot-board-config.patch`
3. Cek toolchain (akan **GAGAL di Windows** — itu normal dan diharapkan)

## B2. Verifikasi hasilnya

Cek dua file ini ada:

```
xnu-src-8020\pexpert\pexpert\arm64\TISSOT.h
xnu-src-8020\makedefs\MakeInc.def        (harus mengandung TISSOT)
```

```bat
findstr /C:"MACHINE_FLAGS_ARM64_TISSOT" xnu-src-8020\makedefs\MakeInc.def
```

Harus keluar satu baris berisi `-mcpu=cortex-a53`.

---

# Bagian C — Build kernel lewat GitHub Actions ✅🔒

> Kenapa tidak di PC? XNU butuh clang + **cctools** (ld, ctf_insert,
> kextsymboltool) + SDK Apple, dan build system-nya berasumsi macOS.
> GitHub menyediakan runner macOS gratis untuk repo publik.

## C1. Buat repo & push

1. Buat repo baru di GitHub (boleh **private**).
2. Di folder proyek:

```bat
git init
git add .
git commit -m "HakiOS tissot: XNU 8020 port foundation"
git branch -M main
git remote add origin https://github.com/<USERNAME>/<REPO>.git
git push -u origin main
```

> ⚠️ **Jangan commit** IPSW / firmware / `stock-boot.img` (ukuran besar &
> berhak cipta). Tambahkan `.gitignore`:

```
*.ipsw
*.fdmdownload
*.tgz
xnu-src-8020/
devices/tissot/dt/*.img
devices/tissot/dt/*.dtb
prebuilt/*.img
```

## C2. Jalankan workflow

1. Buka tab **Actions** di repo.
2. Pilih workflow **`xnu-tissot`** → **Run workflow** → **Run**.
3. Tunggu ~30–60 menit (build XNU penuh itu lama).

## C3. Unduh hasilnya

Setelah selesai, di halaman run ada **Artifacts** → `xnu-tissot-kernel`.

Isinya (kalau build sukses):

```
tissot-kernel-arm64.Image
```

## C4. Kalau build gagal

Workflow sengaja memakai `--force`, jadi ia **tetap mencoba build** walaupun
precheck toolchain melaporkan sesuatu kurang. Artinya error yang kamu lihat
adalah **error compiler asli**, bukan berhenti di precheck.

Yang perlu dilakukan saat gagal:

1. Buka run yang gagal → **Artifacts** → download **`build-log`**.
2. Cari baris pertama yang berisi `error:` — itu titik masalahnya.
3. Kirim log itu; dari situ bisa ditentukan patch berikutnya (0003 / 0004).

Catatan umum:

- `ctf_insert` / `kextsymboltool` tidak ditemukan → runner butuh Xcode
  command line tools versi penuh, atau pakai image
  `blacktop/darwin-xnu-build` (yang dipakai ios-sweet), atau build di Mac fisik.
- Error di `pexpert/arm/pe_identify_machine.c` → butuh patch 0003 (platform
  identify / ADT).

Langkah 0002–0004 di `docs/XNU8020-PORT-PLAN.md` kemungkinan masih perlu
ditulis sebelum build benar-benar bersih. Kalau build gagal di file tertentu,
itulah petunjuk patch berikutnya yang harus dibuat.

---

# Bagian D — Komponen iOS 15.6.1

## D1. Ekstrak DeviceTree d22ap ✅

```bat
python tools\extract_adt.py "F:\SETUP\iPhone10,3,iPhone10,6_15.6.1_19G82_Restore.ipsw"
```

Hasil di `devices\tissot\dt\`:

```
DeviceTree.d22ap.im4p
d22ap.adt.lzfse        (payload LZFSE, belum di-decompress)
```

## D2. Decompress ADT ✅

Pilih salah satu:

```bat
pip install lzfse
python tools\extract_adt.py "F:\SETUP\...15.6.1_19G82_Restore.ipsw"
```

atau pakai tool `ipsw`:

```bat
ipsw img4 im4p extract devices\tissot\dt\DeviceTree.d22ap.im4p -o devices\tissot\dt\d22ap.adt
```

## D3. Rakit root iOS (HFS+) ⏳

Langkah ini butuh `mkiosroot.sh` dari ios-sweet (belum ada di repo ini).
Intinya: gabungkan **OS.dmg + SystemOS.dmg + AppOS.dmg** dari IPSW jadi satu
volume HFS+ case-sensitive, jalankan tweak root, lalu `img2simg`.

Butuh Linux dengan `apfs-fuse`, `hfsprogs`, dan `img2simg`.

## D4. Ukuran root ✅ (info)

Root iOS butuh ruang besar. ios-sweet memakai 16 GB. Siapkan space di
`userdata` HP (Mi A1 64 GB → aman).

---

# Bagian E — Rakit boot image

## E1. Pakai kernel hasil build ✅

```bat
cd devices\tissot
bash build-bootimage.sh --kernel ..\..\prebuilt\tissot-kernel-arm64.Image
```

Atau manual dari root proyek:

```bat
python tools\make_tissot_bootimg.py --kernel prebuilt\tissot-kernel-arm64.Image
```

## E2. Verifikasi ✅

Output yang benar terlihat seperti:

```
kernel check    = arm64 Image magic 'ARM\x64' OK (Image.gz-dtb, <size> bytes)
dtb check       = FDT magic OK, totalsize=<n> (matches)
sha1 id         = <hash>  (matches stored)
Wrote: prebuilt\tissot-boot.img
```

---

# Bagian F — Flash & boot

## F1. Cek koneksi 🔒

```bat
fastboot devices
```

## F2. (Kalau root iOS sudah siap) flash root ⏳

```bat
fastboot -S 512M flash userdata ios16-root.simg
```

> Proses ini ~7 menit. **Jangan cabut kabel.** Kalau fastboot hang setelah
> flash besar, masuk ulang fastboot dengan **Power + Volume Down**.

## F3. Boot TANPA flash (aman) 🔒

```bat
fastboot boot prebuilt\tissot-boot.img
```

Ini **tidak menulis apa pun** ke HP. Kalau macet, tahan **Power** 10–15 detik.

## F4. Baca log lewat UART 🔒⏳

Ini satu-satunya cara melihat apa yang terjadi sebelum display hidup.

1. Buka Mi A1 (butuh akses ke test point UART — pekerjaan hardware).
2. Sambungkan USB-UART 3.3V ke TX/RX/GND di `0x78AF000` (BLSP1 UART1).
3. Buka serial: **115200 8N1**.
4. `fastboot boot prebuilt\tissot-boot.img` dan lihat log.

Tanpa driver UART di kernel (patch 0002, belum ada), **layar akan tetap
hitam dan UART juga diam**. Itu kondisi saat ini.

## F5. Yang diharapkan setelah patch 0002–0004 selesai ⏳

| Tahap | Yang terlihat |
|-------|---------------|
| UART hidup | teks log XNU mulai keluar di 115200 |
| Platform init | XNU mendeteksi CPU/RAM |
| Driver display | logo / teks di layar |
| Root mount | launchd jalan |
| SpringBoard | lock screen iOS |

---

# Bagian G — Rollback (kalau ada masalah) 🔒

## G1. Kembalikan boot stock

```bat
fastboot flash boot devices\tissot\dt\stock-boot.img
fastboot reboot
```

## G2. Kalau HP tidak mau boot sama sekali

1. Tahan **Power + Volume Down** → masuk fastboot.
2. Flash boot stock (G1).
3. Kalau masih gagal: flash firmware stock lengkap dengan **MiFlash**
   memakai tgz yang kamu punya (`tissot_images_V10.0.24.0.PDHMIXM`).

> Simpan `stock-boot.img` di dua tempat berbeda. Ini jaring pengamanmu.

---

# Bagian H — Troubleshooting

| Gejala | Penyebab umum | Solusi |
|--------|---------------|--------|
| `fastboot devices` kosong | driver / kabel / mode | coba kabel lain, install driver Qualcomm, pastikan di fastboot (bukan adb) |
| `fastboot boot` → layar hitam | kernel placeholder / belum ada driver | **normal** untuk tahap ini; lihat F4 |
| `dtb not found` | `qcom,board-id` tidak cocok | DTB kita sudah `<0x1000b 0>`; pastikan pakai `prebuilt/tissot.dtb` terbaru |
| `Image not a valid arm64 kernel` | kernel bukan format `Image` | pastikan hasil build XNU, bukan ELF |
| Bootloop setelah `flash boot` | kernel salah | G1 (flash boot stock) |
| Actions gagal di `ctf_insert` | runner tanpa cctools penuh | lihat C4 |
| IPSW tidak bisa dibuka | download belum selesai | cek ukuran = 5.777.710.157 byte |

---

# Ringkasan: apa yang bisa dilakukan hari ini

| Bagian | Status |
|--------|--------|
| A1–A2 (tools) | ✅ |
| A3 (unlock) | 🔒 butuh HP + waktu tunggu Mi Unlock |
| A4–A5 (backup, IPSW) | ✅ |
| B (source + patch) | ✅ **sudah jalan** |
| C (build CI) | ✅ workflow siap, tapi kernel kemungkinan masih gagal → butuh patch 0002–0004 |
| D1–D2 (DeviceTree + ADT) | ✅ |
| D3 (root iOS) | ⏳ butuh `mkiosroot.sh` |
| E (boot image) | ✅ pipeline siap |
| F (flash/boot) | 🔒 + ⏳ butuh kernel & driver |
| G (rollback) | ✅ |

**Intinya:** semua yang tidak butuh macOS dan tidak butuh hardware sudah
selesai dan bisa dijalankan sekarang. Yang tersisa adalah pekerjaan kernel
(patch 0002–0004) dan komponen ios-sweet (`mkadt`, `shim`, `mkiosroot`).
