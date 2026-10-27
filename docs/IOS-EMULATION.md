# Menjalankan iOS (ARM64) di PC x86 via Emulasi QEMU

> **Peringatan awal.** "Port ke x86" secara native **tidak bisa** untuk user space
> iOS, karena binary iOS adalah **ARM64 Mach-O** dan tidak ada translator
> ARM→x86 yang tersedia untuk iOS. Satu-satunya cara melihat iOS *asli* di PC x86
> adalah **emulasi ARM64**: CPU ARM64 disimulasikan di atas x86 (QEMU TCG).
> Ini bukan port — ini ARM yang berjalan di-emulasi. Berat, lambat, dan bukan
> jalan satu klik.

---

## 1. Arsitektur emulasi

```
PC x86_64 (Windows / Linux)
  └─ QEMU (TCG, target aarch64)      ← CPU ARM64 disimulasikan di x86
       ├─ ARM64 XNU kernel           ← dari Apple XNU (arm64) / kernelcache IPSW
       ├─ Device tree (d22ap)        ← diekstrak dari IPSW (lihat step 2)
       └─ iOS root (HFS+ / APFS)     ← OS.dmg + SystemOS.dmg + AppOS.dmg
            └─ launchd → SpringBoard → iOS GUI (semua ARM64, di-emulasi)
```

Kuncinya: **host x86**, tapi **guest ARM64**. QEMU menerjemahkan setiap instruksi
ARM64 ke x86 saat runtime (binary translation / TCG). Makanya lambat.

---

## 2. Tools yang wajib

| Kebutuhan | Keterangan |
|-----------|------------|
| **QEMU yang bisa boot XNU di ARM64** | **Bukan** QEMU vanilla. XNU butuh *device quirks* Apple yang tidak ada di QEMU standar. Pakai fork yang sudah dipatch, mis. `alephsecurity/xnu-qemu-arm64` (proyek riset yang mem-patch QEMU supaya bisa boot XNU/macOS/iOS di emulasi ARM64). |
| **ARM64 XNU kernel** | Build sendiri dari Apple XNU (`ARCH_CONFIGS=ARM64`), **atau** ekstrak + dekompres `kernelcache` dari IPSW. |
| **iOS root image** | `ios16-root.img` / `.simg` hasil `mkiosroot.sh` (step 2 yang sudah kamu punya). |
| **Device tree** | `d22ap.dtb` hasil ekstrak `DeviceTree.d22ap.im4p` dari IPSW. |
| **Host x86 + QEMU** | Windows: `qemu-system-aarch64.exe`. Build fork di atas lebih mudah di Linux/WSL, lalu jalankan binary-nya di Windows. |

> Catatan: repo fork QEMU di atas berkembang tiap tahun — cek upstream terkini
> sebelum build. Intinya: **stock QEMU tidak bisa boot XNU**, wajib pakai yang
> sudah dipatch untuk XNU.

---

## 3. Alur kerja (skeleton)

1. **Clone & build** fork `xnu-qemu-arm64` → dapat `qemu-system-aarch64` yang
   sudah bisa boot XNU. (Lihat petunjuk build di repo mereka; biasanya butuh
   Linux build env + compiler.)
2. **Siapkan artifact boot**: kernel ARM64 (`Image`/`bin`), device tree `.dtb`,
   ramdisk (opsional), dan iOS root HFS+ (`ios16-root.img`).
3. **Attach** iOS root sebagai disk (`-drive ... file=ios16-root.img`).
4. **Jalankan** QEMU dengan argumen mesin/CPU/memori/kernel/dtb/disk/serial.
5. **Lihat serial** — XNU boot, mount root, jalankan `launchd`.

---

## 4. Command skeleton (contoh, perlu penyesuaian)

```bash
qemu-system-aarch64 \
  -M virt,highmem=off \
  -cpu cortex-a72 \
  -smp 4 -m 4096 \
  -kernel path/ke/kernel-Image \
  -dtb    path/ke/d22ap.dtb \
  -append "root=/dev/vda ro" \
  -drive  file=ios16-root.img,format=raw,if=virtio \
  -serial stdio \
  -display none
```

> Ini **hanya skeleton umum**. Boot XNU di QEMU butuh param & patch spesifik dari
> repo `xnu-qemu-arm64` (mereka biasanya sediakan script/example). Tidak ada
> one-liner ajaib.

---

## 5. Realita & risiko (baca sebelum buang waktu)

- **Lambat.** TCG emulasi = 5–20× lebih lambat dari native. iOS GUI sangat
  berat → bisa nyaris tidak responsif.
- **Stock QEMU TIDAK boot XNU.** Wajib fork yang dipatch.
- **iOS GUI penuh di QEMU = belum turnkey.** ios-sweet target *bare-metal*
  Redmi (ARM asli). Jalur QEMU untuk user space iOS lengkap (SpringBoard,
  backboardd, framework) belum ada solusi jadi. Yang umum dikerjakan peneliti =
  **kernel XNU + ramdisk minimal**, bukan GUI penuh.
- **Device tree / MobileGestalt / aktivasi.** Tweak `sweet-root-tweaks.py`
  mengasumsikan hardware iPhone nyata. Di emulasi butuh penyesuaian lagi
  (perangkat virtual).
- **Legal.** IPSW dari punyamu sendiri (Apple CDN). Jangan distribusikan file iOS.

---

## 6. Bandingkan dengan jalur HakiOS-x86 (open mode)

| | Emulasi iOS (jalur ini) | HakiOS-x86 open mode |
|---|---|---|
| ISA | ARM64 di-emulasi di x86 | x86_64 native |
| Kernel | XNU ARM64 (emulasi) | XNU x86_64 (native) |
| User space | iOS asli (ARM64, lambat) | user space x86 buatan kita |
| iOS GUI | ya (kalau berhasil, lambat) | **tidak** |
| Kemudahan boot | sulit, butuh fork QEMU | lebih realistis |

---

## 7. Rekomendasi

- Tujuan = **"lihat/pahami iOS boot"**: pakai emulasi + `xnu-qemu-arm64` +
  ramdisk minimal (fokus kernel, bukan GUI). Ini jalur riset.
- Tujuan = **"punya sistem yang jalan di PC"**: HakiOS-x86 **open mode** (XNU
  x86_64 + user space x86 kita) jauh lebih mungkin benar-benar boot.

Keduanya sah; cuma punya trade-off beda. Emulasi = iOS asli tapi lambat/sulit.
Open mode = boot native di PC tapi bukan iOS GUI.
