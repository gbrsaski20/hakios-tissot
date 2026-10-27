# iOS 15 vs iOS 16 untuk target ARMv8.0 (Mi A1 / MSM8953)

Dokumen ini menjawab pertanyaan: **boleh tidak pakai iOS 15, bukan 16?**

Jawaban: **boleh, dan justru itu pilihan yang benar** untuk SoC ARMv8.0 seperti
Snapdragon 625 di Mi A1. Alasannya bukan selera, tapi fakta dukungan perangkat.

---

## 1. Argumen inti

Apple mengirim **satu keluarga binary `arm64` per versi iOS** yang harus bisa
boot di perangkat arm64 **tertua** yang masih didukung versi itu.

| iOS | Perangkat arm64 tertua | SoC | Level ARM |
|-----|------------------------|-----|-----------|
| iOS 15 | iPhone 6s / SE 1st gen | **A9** | **ARMv8.0-A** |
| iOS 16 | iPhone 8 / X | A11 | ARMv8.2-A |

Konsekuensinya:

* **iOS 15** — karena harus jalan di A9 (ARMv8.0), binary `arm64`-nya
  **tidak boleh** memakai instruksi ARMv8.1/8.2 (LSE atomics, FP16 aritmetika,
  dan sejenisnya). Ini berlaku untuk kernel, dyld shared cache, launchd,
  SpringBoard, dan seluruh framework.
* **iOS 16** — A9/A10 dibuang, minimum A11 (ARMv8.2). Apple **bebas** memakai
  instruksi ARMv8.1/8.2. Di Cortex-A53 instruksi seperti itu akan
  `SIGILL` / fault.

Jadi risiko terbesar port ini (lihat `docs/PORT-TISSOT.md` §6) **hilang hampir
seluruhnya** kalau kita pakai iOS 15.

---

## 2. Bukti (data firmware resmi, diambil 2026-10-27)

Sumber: `https://api.ipsw.me/v4/device/<Identifier>?type=ipsw`

| Identifier | Perangkat | SoC | iOS 15 terakhir | Jumlah build iOS 15 | Build iOS 16 |
|------------|-----------|-----|-----------------|---------------------|--------------|
| `iPhone8,1` | iPhone 6s | A9 (ARMv8.0) | **15.8.8 (19H422)** — masih signed | 32 | **0** |
| `iPhone10,3` | iPhone X (d22ap) | A11 (ARMv8.2) | 15.6.1 (19G82) | 13 | 32 (s/d 16.7.16) |

Poin kuncinya: **iPhone 6s mendapat iOS 15.8.8 tapi tidak pernah mendapat
iOS 16**. Itu bukti langsung bahwa iOS 15 memang dirancang untuk ARMv8.0.

Cek ulang sendiri:

```bash
curl -s "https://api.ipsw.me/v4/device/iPhone8,1?type=ipsw" | grep -o '"version":"1[56][^"]*"' | sort -u
```

---

## 3. Yang perlu di-download

IPSW **iPhone X, iOS 15.6.1 (19G82)** — build iOS 15 terakhir untuk d22ap:

```
https://updates.cdn-apple.com/2022SummerFCS/fullrestores/012-52718/E165707F-2AA7-40C8-B1A5-0BB94E3F845A/iPhone10,3,iPhone10,6_15.6.1_19G82_Restore.ipsw
```

| Item | Nilai |
|------|-------|
| Versi / build | 15.6.1 / 19G82 |
| Ukuran | 5,38 GiB |
| sha256 (awal) | `e59be5b34321f712beecbffd6c350ba2…` |

Tidak perlu signed — kita hanya **mengambil isi** IPSW (userland + DeviceTree),
bukan me-restore iPhone.

Setelah diunduh, ekstrak DeviceTree-nya:

```bash
python tools/extract_adt.py "F:\SETUP\iPhone10,3,iPhone10,6_15.6.1_19G82_Restore.ipsw"
```

(Default `--device d22ap`; hasil di `devices/tissot/dt/`.)

---

## 4. Apa yang berubah di rencana

| Komponen | iOS 16 (rencana lama) | iOS 15 (rencana baru) |
|----------|----------------------|------------------------|
| Sumber XNU | `xnu-8796` | **`xnu-8020` series** |
| Patch ios-sweet | `xnu/patches/` untuk 8796 | **harus di-port** ke 8020 |
| DeviceTree | `DeviceTree.d22ap.im4p` dari IPSW 16 | dari IPSW **15.6.1** |
| Root iOS | OS/SystemOS/AppOS dari IPSW 16 | dari IPSW **15.6.1** |
| `sweet-root-tweaks.py` | target daemon iOS 16 | **perlu penyesuaian** (iOS 15 lebih sedikit cryptex) |
| ADT (`mkadt.py`) | wajib | **tetap wajib** |
| SHIM (`shim/`) | wajib | **tetap wajib** |
| `mkiosroot.sh`, `mkpayload.py` | wajib | **tetap wajib** |
| Risiko ARMv8.0 | tinggi | **rendah** |

Biaya utama pindah ke iOS 15: **patch XNU ios-sweet menargetkan xnu-8796**,
jadi harus di-port ke xnu-8020. Ini pekerjaan nyata, tapi jauh lebih murah
daripada mengerjakan seluruh port lalu menemukan kernel fault di A53.

---

## 5. Risiko yang masih tersisa

Meski risiko ARMv8.2 hilang, ini masih ada:

1. **Fitur ARMv8.0 opsional.** A53 punya beberapa ekstensi opsional (CRC32
   terpasang di Snapdragon, LSE tidak). Perlu dicek kalau ada fault aneh.
2. **Port patch XNU 8796 → 8020.** Bisa gagal apply; perlu penyesuaian manual.
3. **Driver MSM8953.** UART, display (ft8716/ili7807/otm1911), touch
   (FocalTech FT5435) — belum ada satu pun.
4. **SHIM + ADT** untuk tissot belum ditulis.
5. **Kinerja.** A53 8×2.0 GHz vs A11 — SpringBoard bisa sangat lambat, tapi
   lambat ≠ tidak bisa boot.
6. **Baseband/modem** tidak akan jalan (ios-sweet juga mematikannya).

---

## 6. Rekomendasi

1. **Pakai iOS 15.6.1 (19G82) untuk iPhone X** sebagai basis port.
2. Simpan IPSW 16.7.16 yang sudah kamu punya sebagai **pembanding/referensi**
   (mis. kalau nanti mau membandingkan struktur file antar versi).
3. Verifikasi tambahan (murah): setelah IPSW 15.6.1 ada, jalankan
   `tools/extract_adt.py` dan bandingkan ukuran/struktur ADT d22ap 15 vs 16.
4. Baru masuk Jalur A: fork ios-sweet → build `xnu-8020` di GitHub macOS
   runner → port patch → `mkadt` untuk MSM8953 → shim → root iOS 15 → boot.

---

## 7. Catatan: kenapa tidak pakai identitas iPhone 6s (A9) saja?

Bisa dipertimbangkan, karena A9 adalah ARMv8.0 "asli". Tapi:

* ios-sweet memilih iPhone X karena merupakan **model terakhir tanpa PAC**
  dan punya layar 1125×2436 yang cocok dengan panel FHD Mi A1.
* Pada iOS 15, binary `arm64` sudah pasti ARMv8.0-safe (karena A9 didukung),
  jadi memakai identitas d22ap **tidak menambah risiko** ARMv8.2.

Kesimpulan: tetap pakai **d22ap + iOS 15**, bukan identitas A9.
