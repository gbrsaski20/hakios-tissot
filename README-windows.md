# HakiOS-x86 di Windows (via WSL2)

> ⚠️ **Dokumen ini untuk jalur x86_64 (fase 1), BUKAN untuk Mi A1.**
> Untuk Xiaomi Mi A1 (`tissot`, ARM64), mulai dari
> [`docs/INSTALL-STEP-BY-STEP.md`](docs/INSTALL-STEP-BY-STEP.md) dan
> [`README.md`](README.md).

Proyek ini di-build di dalam **WSL2** (Windows Subsystem for Linux), bukan langsung di Windows. Script `build-windows.ps1` menangani semuanya otomatis.

## Persyaratan

1. **Windows 10 version 2004+** atau **Windows 11**
2. **Virtualization** enabled di BIOS (Intel VT-x / AMD-V)
3. **WSL2** terinstall

## Cara Install WSL (sekali saja)

Buka **PowerShell sebagai Administrator**:

```powershell
wsl --install -d Ubuntu
```

Lalu **restart Windows**.

## Cara Build

```bat
build-windows.bat
```

Atau PowerShell:

```powershell
.\build-windows.ps1
```

### Yang terjadi di balik layar

1. Script cek WSL → cari distro yang tersedia
2. Kalau distro belum ada → install Ubuntu, minta kamu restart, lalu berhenti
3. Kalau distro ada tapi belum di-init → kasih instruksi untuk launch sekali dari Start Menu
4. Install dependencies di dalam WSL (**run sebagai root**, jadi `sudo` tidak minta password)
5. Jalankan `make x86-open`
6. Laporkan binary yang berhasil dibuat

### Mode Build

| Perintah | Hasil | Butuh |
|----------|-------|-------|
| `build-windows.bat` | Open mode | — |
| `build-windows.bat full` | Full mode | iOS IPSW (~7.4 GB) |
| `build-windows.bat clean` | Bersihkan + build | — |

### Opsi tambahan

```powershell
.\build-windows.ps1 -Mode full -Clean
.\build-windows.ps1 -Distro Ubuntu-24.04
```

## Setelah Build: Menjalankan

### Opsi 1: QEMU dari Windows

```bat
run-qemu-windows.bat          # Open mode, 1200 detik
run-qemu-windows.bat 600      # Open mode, 600 detik
run-qemu-windows.bat full     # Full iOS user space
```

### Opsi 2: Manual dari PowerShell

```powershell
wsl -e bash -c "cd /mnt/e/workbuddyainew/2026-10-26-09-55-05 && make qemu-open"
```

### Opsi 3: Bootable USB via Rufus (Rekomendasi untuk Windows)

Cara paling mudah untuk boot HakiOS-x86 di PC fisik.

**Tanpa WSL (Python-only — paling cepat):**

```bat
make-bootable.bat
```

Ini akan build `xnuloader.efi` + `mach_kernel` (placeholder) + `hakios-x86.img` (256 MB) sepenuhnya dengan Python. Tidak butuh WSL, clang, atau mtools.

**Dengan WSL (full build):**

```bat
make-rufus-img.bat
```

Atau langsung:

```powershell
.\build-windows.ps1 -Rufus
```

Ini akan build project + membuat file `prebuilt\hakios-x86.img` (256 MB).

Lalu:
1. Download **Rufus** dari https://rufus.ie
2. Buka Rufus
3. Klik **SELECT**, pilih `prebuilt\hakios-x86.img`
4. **Partition scheme**: GPT
5. **Target system**: UEFI (non-CSM)
6. Klik **START**
7. Kalau Rufus bertanya mode, pilih **DD Image** (bukan ISO)
8. Boot dari USB (aktifkan UEFI di BIOS)

### Opsi 4: Bootable USB manual (Linux/WSL)

```powershell
wsl -e bash -c "cd /mnt/e/workbuddyainew/2026-10-26-09-55-05 && sudo tools/make-boot-usb.sh /dev/sdX"
```

> ⚠️ Ganti `/dev/sdX` dengan device USB kamu. Cek dulu dengan `wsl -e lsblk`.

## Masalah Umum

### "WSL is not available"
Install WSL sebagai Administrator: `wsl --install -d Ubuntu`, lalu restart.

### "The distro is installed but has not been set up yet"
Normal setelah install baru. **Launch Ubuntu dari Start Menu**, buat username + password, jalankan `exit`, lalu run ulang script.

> Password di Linux tidak ditampilkan saat diketik — itu normal, bukan bug.

### "The requested operation is successful. Changes will not be effective until the system is rebooted"
WSL baru di-enable. **Restart Windows**, lalu ulangi.

### Build gagal di bagian kernel
XNU xnu-8796 (macOS 13 Ventura) butuh cctools + macOS SDK yang susah di-dapat di Linux. Coba build loader saja dulu — ini tidak butuh SDK:

```powershell
wsl -e bash -c "cd /mnt/e/workbuddyainew/2026-10-26-09-55-05 && ./xnuloader/build.sh"
```

Kalau `xnuloader.efi` muncul di `prebuilt/`, boot loader-nya berhasil.

### QEMU lambat / crash di WSL2
Nested virtualization di WSL2 bisa bermasalah. Coba:
```powershell
wsl -e bash -c "cd /mnt/e/... && qemu/run-x86.sh 300 --open -display none"
```
Mode headless (`-display none`) lebih stabil. Untuk performa, jalankan Linux di VM (VirtualBox/VMware) sebagai gantinya.

## File Windows

| File | Fungsi |
|------|--------|
| `setup-wsl.bat` | Helper cek kesiapan WSL (step-by-step) |
| `build-windows.ps1` | Build script utama (support `-Rufus`) |
| `build-windows.bat` | Launcher (`rufus`, `python`, `clean` opsi) |
| `make-bootable.bat` | **One-step** Python-only build → Rufus image (tanpa WSL!) |
| `make-rufus-img.bat` | Build + buat `.img` untuk Rufus (WSL atau Python) |
| `run-qemu-windows.bat` | Jalankan QEMU dari Windows |
| `xnuloader/build_efi.py` | Python: bangun `xnuloader.efi` (PE64 UEFI) |
| `tools/build_kernel_placeholder.py` | Python: bangun placeholder `mach_kernel` |
| `tools/make_rufus_img.py` | Python: buat `hakios-x86.img` (MBR + FAT32) |
| `tools/make-rufus-img.sh` | Script WSL untuk buat Rufus image (mtools) |
| `README-windows.md` | Dokumentasi ini |

## Alur Build → USB → Boot

```
build-windows.bat rufus     →  prebuilt\hakios-x86.img  →  Rufus (DD)  →  USB boot
make-rufus-img.bat          →  prebuilt\hakios-x86.img  →  Rufus (DD)  →  USB boot
```

```
build-windows.bat           →  QEMU via run-qemu-windows.bat
```

### Mode Build

| Perintah | Hasil |
|----------|-------|
| `build-windows.bat` | Build open mode |
| `build-windows.bat rufus` | Build + Rufus image |
| `build-windows.bat full` | Build full mode (butuh IPSW) |
| `build-windows.bat clean rufus` | Clean + build + Rufus image |
| `make-rufus-img.bat` | Build + Rufus image (sama seperti `rufus`) |
