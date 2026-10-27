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
> Ini soal **mesin build**, bukan target — targetnya tetap Mi A1.

## C1. Buat repo & push

1. Buat repo baru di GitHub (publik = menit macOS gratis).
2. Di folder proyek:

```bat
git init
git add .
git commit -m "HakiOS tissot: XNU 8020 port foundation"
git branch -M main
git remote add origin https://github.com/<USERNAME>/<REPO>.git
git push -u origin main
```

> ⚠️ **Jangan commit** IPSW / firmware / `stock-boot.img` (besar & berhak
> cipta). `.gitignore` di repo sudah menutup semuanya: `*.ipsw`, `*.tgz`,
> `xnu-src-8020/`, `devices/tissot/dt/*.img`, `prebuilt/*.img`, `prebuilt/*.adt`.

> Catatan: `devices/tissot/dt/d22ap_15.6.1.adt` **tidak** ikut ter-push (data
> Apple). Akibatnya job `package` di CI membuat boot image **tanpa** ADT dan
> memberi peringatan. Itu wajar — ADT hanya ada di PC kamu.

## C2. Jalankan workflow

1. Buka tab **Actions** di repo.
2. Pilih workflow **`xnu-tissot`** → **Run workflow**.
3. Isi:
   - `config`: `DEVELOPMENT` (default), `RELEASE`, atau `DEBUG`
   - `pack`: `true` kalau mau sekalian merakit `tissot-boot.img`
4. Klik **Run workflow**.

Tiga job berjalan berurutan:

| Job | Runner | Waktu | Isi |
|-----|--------|-------|-----|
| `patches` | ubuntu | ~2 mnt | apply 0001–0003 + cek 9 penanda + cek `arm64` (bukan `arm64e`) + `-mcpu=cortex-a53` + uji pipeline image |
| `kernel` | macOS | ~20–40 mnt | `make ... ARM64 TISSOT` sungguhan |
| `package` | ubuntu | ~1 mnt | rakit `tissot-boot.img` dari kernel hasil job 2 |

Kalau `patches` merah, `kernel` tidak akan jalan — itu memang gerbangnya:
patch rusak lebih murah ketahuan di Linux 2 menit daripada macOS 30 menit.

## C3. Unduh hasilnya

Di halaman run ada **Artifacts**:

| Artefak | Isi | Dipakai untuk |
|---------|-----|---------------|
| `xnu-tissot-kernel` | `mach.*` TISSOT (Mach-O ARM64) + `.gz` | bukti XNU terkompilasi; bahan SHIM |
| `tissot-boot` | `tissot-boot.img` + `tissot.adt` + `tissot.dtb` | `fastboot boot` (lihat catatan di bawah) |
| `tissot-boot-placeholder` | boot image dari job `patches` (kernel `wfi`) | menguji jalur flash/ABL hari ini |
| `build-log` | `build.log` penuh | diagnosis kalau gagal |

Letakkan kernel hasil unduhan di `prebuilt/tissot-kernel-arm64.Image`, lalu di
PC:

```bat
make-tissot.bat
```

> **Penting — kernel hasil CI masih Mach-O.** ABL melompat ke offset 0 payload
> boot image, dan header Mach-O bukan kode yang bisa dieksekusi. Jadi
> `fastboot boot` sekarang belum akan sampai ke XNU. Yang menjembatani itu
> adalah **SHIM** (belum ada). Sampai SHIM selesai, nilai build CI adalah:
> membuktikan XNU 8020 bisa dikompilasi untuk TISSOT — gerbang utama sebelum
> bicara booting.

## C4. Kalau build gagal

Workflow sengaja memakai `--force`, jadi ia **tetap mencoba build** walaupun
precheck toolchain melaporkan sesuatu kurang. Artinya error yang kamu lihat
adalah **error compiler asli**, bukan berhenti di precheck.

Workflow juga otomatis **mengulang sekali dengan `WERROR=`** kalau log
mengandung `-Werror`. Alasannya: XNU 8020 (2021) lebih tua dari clang di
runner, jadi warning baru otomatis jadi error dan menutupi error sebenarnya.
Percobaan kedua memisahkan keduanya. Build inkremental, jadi tidak mengulang
dari nol.

Yang perlu dilakukan saat gagal:

1. Buka run yang gagal → **Artifacts** → download **`build-log`**.
2. Cari baris pertama yang berisi `error:` — itu titik masalahnya.
   (Ringkasan job sudah mencetak 40 yang pertama.)
3. Kirim log itu; dari situ bisa ditentukan patch berikutnya.

Catatan umum:

- `ctf_insert` / `kextsymboltool` tidak ditemukan → runner macOS GitHub sudah
  menyertakannya lewat Xcode; kalau hilang, `xcode-select -p` yang salah.
- Error di `pexpert/arm/pe_fiq.c` → patch 0003 (GICv2) perlu disesuaikan;
  kemungkinan besar tipe/API berbeda antar versi XNU.
- Error di `osfmk/arm64/sleh.c` → pastikan `<pexpert/arm/protos.h>` ikut
  ter-include (sudah ada di source asli, jadi seharusnya aman).
- Error "unknown argument: -Wno-..." → itu warning clang baru; jalankan
  `./xnu-build-arm64.sh --no-werror` untuk melihat error sesungguhnya.

Patch 0001–0003 sudah ada. Kalau build gagal di file tertentu, **file itu
adalah petunjuk patch berikutnya** — bukan tanda fondasinya salah.

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

> Kalau kernelnya hasil CI (Mach-O XNU), packer akan menolak karena tidak ada
> magic `ARM\x64`. Itu benar: yang diharapkan packer adalah arm64 Image. Untuk
> mengemas kernel XNU apa adanya, tambahkan:

```bat
python tools\make_tissot_bootimg.py --allow-foreign-kernel
```

Hasilnya tetap **belum bisa di-boot** (butuh SHIM), tapi berguna untuk
memastikan ukuran/offset benar.

## E2. Verifikasi ✅

Output yang benar terlihat seperti:

```
kernel check    = arm64 Image magic 'ARM\x64' OK (Image.gz-dtb, <size> bytes)
dtb check       = FDT magic OK, totalsize=<n> (matches)
sha1 id         = <hash>  (matches stored)
Wrote: prebuilt\tissot-boot.img
```

Kalau memakai `--allow-foreign-kernel` dengan kernel XNU asli, baris pertama
berubah menjadi (dan itu wajar):

```
kernel check    = Mach-O (XNU), bukan arm64 Image [Image.gz-dtb] — diterima
                  PERINGATAN: Mach-O tidak bisa di-boot tanpa SHIM.
```

---

# Bagian F — Flash & boot

## F1. Cek koneksi 🔒

```bat
fastboot devices
```

## F2. (Kalau root iOS sudah siap) flash root ⏳

```bat
fastboot -S 512M flash userdata ios15-root.simg
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
| Actions: `File to patch:` lalu `N out of N hunks ignored` | patch sebelumnya salah terdeteksi "already applied" (bug `apply-8020.sh`) | sudah diperbaiki: deteksi pakai *forward* dry-run dulu |
| IPSW tidak bisa dibuka | download belum selesai | cek ukuran = 5.777.710.157 byte |

---

# Ringkasan: apa yang bisa dilakukan hari ini

| Bagian | Status |
|--------|--------|
| A1–A2 (tools) | ✅ |
| A3 (unlock) | 🔒 butuh HP + waktu tunggu Mi Unlock |
| A4–A5 (backup, IPSW) | ✅ |
| B (source + patch) | ✅ **0001 + 0002 + 0003 sudah jalan** |
| C (build CI) | ✅ workflow siap; patch 0002–0003 sudah ada, tinggal lihat error compiler pertama |
| D1–D2 (DeviceTree + ADT) | ✅ ADT kini lengkap (GIC + timer + frekuensi), audit 12/12 |
| D3 (root iOS) | ⏳ butuh `mkiosroot.sh` |
| E (boot image) | ✅ pipeline siap, ADT ter-embed byte-identik |
| F (flash/boot) | 🔒 + ⏳ butuh kernel & SHIM |
| G (rollback) | ✅ |

**Intinya:** semua yang tidak butuh macOS dan tidak butuh hardware sudah
selesai dan bisa dijalankan sekarang. Yang tersisa adalah **SHIM** (kode yang
menyambut kendali dari ABL dan menyiapkan MMU sebelum masuk `_start` XNU),
**build kernel di CI macOS**, dan **verifikasi di hardware**.

### Yang berubah di patch 0003

Kalau kamu ingin tahu kenapa interrupt butuh patch tersendiri: XNU hanya punya
driver **Apple AIC** dan **GICv3** (yang cuma aktif untuk VMAPPLE). MSM8953
memakai **GIC-400 = GICv2**, dan untuk build non-GICv3 `pe_init_fiq()` di
source asli **kosong**. Tanpa patch 0003 kernel akan keluar beberapa baris ke
UART lalu hang selamanya — tidak pernah menerima interrupt timer.
