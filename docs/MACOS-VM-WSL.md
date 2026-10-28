# macOS di WSL2 lewat QEMU/KVM — untuk membangun kernel XNU

Panduan ini memasang macOS di dalam WSL2, supaya `tools/wsl-build.sh` bisa
sampai ke tahap kompilasi kernel tanpa keluar dari PC ini.

Baca bagian **0** dulu. Kalau angka-angkanya tidak masuk, lebih baik berhenti
sebelum menghabiskan 40 GB dan beberapa jam.

---

## 0. Harga yang dibayar

| Item | Perkiraan |
|---|---|
| Unduh installer Apple (BaseSystem) | ~700 MB |
| Disk VM setelah macOS terpasang | ~25 GB |
| Xcode | ~10–15 GB |
| **Total disk** | **~40–50 GB** |
| Waktu pasang macOS (installer + boot pertama) | 40–90 menit |
| Waktu unduh + pasang Xcode | 30–60 menit |
| RAM untuk VM | 8 GB (dari 16 GB — sisa untuk Windows tipis) |
| Waktu build XNU di VM | 20–40 menit |

Di mesin ini (Ryzen 5 4600G, 16 GB, E: bebas 119 GB) semuanya masuk, tapi RAM
adalah yang paling ketat: 8 GB untuk VM berarti Windows hanya pegang ~6 GB.

**Yang didapat:** satu-satunya hal yang benar-benar tidak bisa dikerjakan di
WSL, yaitu kompilasi kernel. Sisanya (patch, ADT, DTB, boot image, shim) sudah
bisa dikerjakan di WSL tanpa VM.

---

## 1. Gerbang: `/dev/kvm`

Ini penentu segalanya. Tanpa `/dev/kvm`, QEMU turun ke emulasi TCG murni —
macOS bisa butuh lebih dari 30 menit hanya untuk sampai installer, dan build
Xcode praktis tidak selesai.

Jalankan di WSL:

```bash
bash tools/macos-vm-preflight.sh --dir /mnt/e/macos-vm
```

Kalau hasilnya `SIAP`, lewati bagian 2. Kalau `/dev/kvm` FAIL, lanjut ke
bagian 2.

Kenapa bisa tidak ada: WSL2 sendiri sudah berjalan di atas hypervisor
Windows. Supaya QEMU di dalamnya bisa memakai KVM, dua hal harus benar —
Windows meneruskan ekstensi virtualisasi (SVM di AMD, VMX di Intel) ke guest
WSL, **dan** kernel WSL menyertakan modul KVM. Yang pertama diatur dari
Windows; yang kedua belum tentu ada di kernel bawaan Microsoft.

---

## 2. Kalau `/dev/kvm` tidak ada

### 2a. Nyalakan nested virtualization di Windows

Buat atau sunting `C:\Users\<nama>\.wslconfig`:

```ini
[wsl2]
nestedVirtualization=true
memory=10GB
processors=6
swap=2GB
```

`memory=10GB` penting: VM macOS akan minta 8 GB, dan tanpa ini WSL hanya
kebagian sebagian dari 16 GB.

Lalu dari PowerShell/CMD:

```powershell
wsl --shutdown
wsl
```

Cek lagi:

```bash
grep -o -m1 -E 'svm|vmx' /proc/cpuinfo | head -1   # harus keluar svm (AMD)
ls -l /dev/kvm
```

Kalau `svm` sudah muncul tapi `/dev/kvm` masih tidak ada, lanjut 2b.

### 2b. Bangun kernel WSL dengan KVM aktif

Kernel WSL bawaan tidak selalu menyertakan `CONFIG_KVM`. Membangunnya sendiri
sekali jalan, dan hasilnya dipakai terus.

```bash
sudo apt update
sudo apt install -y build-essential flex bison libssl-dev libelf-dev bc

cd ~
git clone --depth 1 https://github.com/microsoft/WSL2-Linux-Kernel.git -b linux-msft-wsl-6.6.y
cd WSL2-Linux-Kernel
cp Microsoft/config-wsl .config

# aktifkan KVM (modul). AMD -> KVM_AMD, Intel -> KVM_INTEL
scripts/config --module CONFIG_KVM
scripts/config --module CONFIG_KVM_AMD
# scripts/config --module CONFIG_KVM_INTEL    # kalau CPU Intel

make -j"$(nproc)"
```

Salin hasilnya ke Windows, lalu arahkan `.wslconfig` ke situ:

```bash
mkdir -p /mnt/c/Users/$USER/wsl
cp arch/x86/boot/bzImage /mnt/c/Users/$USER/wsl/wsl-kvm-kernel
```

```ini
[wsl2]
kernel=C:\\Users\\<nama>\\wsl\\wsl-kvm-kernel
nestedVirtualization=true
memory=10GB
processors=6
```

```powershell
wsl --shutdown
```

Setelah masuk lagi:

```bash
sudo modprobe kvm_amd
ls -l /dev/kvm
```

Kalau `/dev/kvm` sudah ada, gerbang lewat.

> Catatan: kalau setelah semua ini `/dev/kvm` tetap tidak muncul, jangan
> dipaksa. Pakai jalur alternatif di bagian 8.

---

## 3. Siapkan QEMU dan OSX-KVM

```bash
sudo apt install -y qemu-system-x86 qemu-utils dmg2img wget git

mkdir -p /mnt/e/macos-vm
cd /mnt/e/macos-vm
git clone --depth 1 --recursive https://github.com/kholia/OSX-KVM.git
cd OSX-KVM
```

Proyek ini yang menyediakan OpenCore, skrip boot, dan firmware OVMF. README
di repo itu yang jadi acuan resmi — versi di bawah bisa berubah.

---

## 4. Unduh installer dari Apple

```bash
./fetch-macOS-v2.py
```

Pilih **Ventura** atau **Sonoma**. Jangan yang terbaru: macOS 15+ di QEMU
lebih rewel soal fitur CPU, dan Xcode 15/16 sudah cukup untuk membangun XNU
8020.

Script ini mengunduh `BaseSystem.dmg` langsung dari server Apple
(`osrecovery.apple.com`). Ini jalur resmi — tidak ada image pihak ketiga.

```bash
dmg2img -i BaseSystem.dmg BaseSystem.img
qemu-img create -f qcow2 mac_hdd_ng.img 128G
```

`128G` itu ukuran maksimum, bukan pemakaian: qcow2 bersifat sparse, jadi baru
terisi seiring instalasi.

---

## 5. Pasang macOS

```bash
./OpenCore-Boot.sh
```

Sebelum menjalankan, buka script itu dan perhatikan baris `-cpu`. Di host
**AMD**, macOS butuh model CPU Intel yang eksplisit — untuk Ventura/Sonoma
pakai baris `Haswell-noTSX-IBRS` (biasanya sudah ada sebagai komentar di
script). `-cpu host` tidak bisa dipakai.

Di installer:

1. **Disk Utility** → pilih `Apple Inc. VirtIO Block Media` → **Erase** →
   format **APFS** → nama bebas.
2. Tutup Disk Utility → **Install macOS** → pilih disk tadi.
3. Setelah selesai dan reboot, pilih disk di OpenCore.

Pertama boot bisa 5–10 menit. Itu normal di VM.

---

## 6. Siapkan Xcode di dalam VM

Di dalam macOS, buka Terminal:

```bash
xcode-select --install
```

Lalu pasang Xcode dari App Store (atau dari developer.apple.com). Setelah ada:

```bash
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
xcrun -sdk iphoneos -show-sdk-path    # harus mencetak path SDK
```

Kalau perintah terakhir mengeluarkan path, syarat kompilasi XNU sudah lengkap.

---

## 7. Bawa repo ke dalam VM dan build

Cara paling sederhana tanpa perlu shared folder: sajikan lewat HTTP dari WSL.

Di WSL:

```bash
cd /mnt/e/workbuddyainew/2026-10-26-09-55-05
python3 -m http.server 8000
```

Lalu di Safari dalam macOS, buka `http://<ip-wsl>:8000/`. Cari IP WSL dengan
`hostname -I` di WSL. Kalau bingung soal jaringan QEMU, alternatifnya: zip
repo, lalu kirim lewat email ke diri sendiri atau unggah ke layanan file.

Setelah repo ada di dalam VM:

```bash
cd ~/hakios-tissot
bash tools/wsl-build.sh
```

Di macOS, script ini otomatis memakai `xcrun` asli (tidak memasang shim) dan
menjalankan `xnu-build-arm64.sh` dengan `SDKROOT` dari Xcode.

Hasilnya: `xnu-src-8020/BUILD/obj/.../kernel.development.tissot`.

---

## 8. Kalau mentok

| Gejala | Sebab | Jalan keluar |
|---|---|---|
| `/dev/kvm` tetap tidak ada | kernel WSL tanpa KVM | pakai QEMU untuk Windows + WHPX (di bawah) |
| QEMU jalan tapi sangat lambat | TCG, bukan KVM | sama |
| macOS tidak mau boot di OpenCore | `-cpu` salah untuk host AMD | pakai `Haswell-noTSX-IBRS` |
| Installer tidak melihat disk | VirtIO belum terpasang | pastikan pakai `mac_hdd_ng.img` yang sudah dibuat |
| Xcode tidak mau jalan | macOS terlalu tua | naikkan ke Sonoma |

**Jalur alternatif tanpa WSL: QEMU untuk Windows + WHPX.** Hyper-V di mesin
ini sudah aktif, jadi akselerasi tersedia tanpa nested virtualization.
Unduh QEMU untuk Windows (`qemu.weilnetz.de` atau `winget install
SoftwareFreedomConservancy.QEMU`), lalu jalankan perintah QEMU yang sama
dengan `-accel whpx` menggantikan `-accel kvm`. Skrip `OpenCore-Boot.sh` dari
OSX-KVM bisa dijalankan lewat Git Bash dengan `qemu-system-x86_64.exe`.

---

## 9. Kalau akhirnya tidak jadi

Tidak apa-apa. Yang benar-benar dibutuhkan dari macOS hanyalah **satu kali
kompilasi**, dan itu bisa dicapai dengan:

- meminjam Mac siapa pun selama ~40 menit (`bash tools/wsl-build.sh` langsung
  jalan di sana), atau
- satu kali menjalankan workflow dari tab Actions.

Sementara itu, semua pekerjaan lain — patch, ADT, DTB, boot image, dan
**shim** yang sekarang jadi penghalang terbesar — bisa dikerjakan penuh di
WSL.
