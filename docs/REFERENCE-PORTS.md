# Proyek pembanding — apa yang bisa dipelajari

Dua sumber acuan untuk port XNU ke Android:

- <https://hackiosx.dev/porting> — panduan porting 8 langkah, netral terhadap
  proyek/toolchain.
- <https://github.com/dipa-studio/ios-sweet#how-to-do-it-yourself> — port
  lengkap yang sudah jalan di HP nyata (Redmi Note 10 Pro, SM7150).

Dokumen ini mencatat apa yang **mengonfirmasi** keputusan kita, apa yang
**berbeda dan berisiko**, dan apa yang **belum kita kerjakan**.

## Perbandingan

| | ios-sweet | HakiOS-tissot (kita) |
|---|---|---|
| HP | Redmi Note 10 Pro (`sweet`) | Xiaomi Mi A1 (`tissot`) |
| SoC | SM7150 (Snapdragon 730G) | MSM8953 (Snapdragon 625) |
| Core | Cortex-A76 + A55 | 8× Cortex-A53 |
| Level ARM | ARMv8.2 | **ARMv8.0** |
| Interrupt controller | **GICv3** | **GIC-400 (GICv2)** |
| XNU | `xnu-8796` (iOS 16) | `xnu-8020.140.41` (iOS 15) |
| Jumlah patch | 69 | 8 |
| Build kernel | runner macOS GitHub Actions | macOS (CI dimatikan atas permintaan) |
| Build shim | Linux, `aarch64-linux-gnu-gcc` | **belum ada** |
| Build root image | Linux, `apfs-fuse` + `hfsprogs` | belum |
| ADT | `tools/mkadt.py` | `tools/mkadt.py` |

## Yang mengonfirmasi keputusan kita

**1. Kernel memang hanya bisa dibangun di macOS.** ios-sweet menaruh build
kernel sepenuhnya di runner macOS, dan build system yang mereka pakai
(`blacktop/darwin-xnu-build`) mensyaratkan Xcode + KDK — bukan Docker, bukan
Linux. Jadi "build kernel di WSL" bukan sesuatu yang terlewat, memang tidak
ada jalannya. Ini konsisten dengan temuan kita sendiri: `xcrun`, `ld64`,
`ctf_insert`, `kextsymboltool`, dan header SDK iPhoneOS semuanya biner macOS.

**2. Memilih generasi iOS yang lebih tua itu benar.** Panduan porting
langkah 4 menuliskan gejala "Crashes on older chips → Unsupported newer
instructions", dan solusinya emulasi instruksi ARMv8.2 di chip ARMv8.0.
ios-sweet memakai 8796 karena SM7150 memang ARMv8.2. Kita memakai 8020 (iOS
15) justru supaya tidak perlu emulasi apa pun di A53. Arah kita lebih murah.

**3. Pembagian kerja lintas host itu normal.** ios-sweet tidak membangun
semuanya di satu tempat:

| Tahap | Host |
|---|---|
| Kernel XNU | macOS (runner CI) |
| Shim / boot image | **Linux** (`aarch64-linux-gnu-gcc`) |
| Root image iOS | Linux (`apfs-fuse`, `hfsprogs`) |

Artinya permintaan "kerjakan di WSL" **bisa dipenuhi untuk sebagian besar
pekerjaan** — lihat bagian terakhir.

**4. Sebagian besar patch bersifat umum, bukan per-HP.** Panduan porting
mencatat pengalaman Pixel 6a → ios-sweet: dari 81 patch, ~66 tidak
tergantung HP, ~10 hanya perlu ganti alamat, dan hanya ~5 yang benar-benar
driver hardware Qualcomm. Jadi 8 patch kita sekarang bukan 8 dari 69 yang
harus ditulis ulang satu per satu — banyak sisanya bisa diangkat.

## Yang berbeda dan berisiko

**GICv2 adalah satu-satunya bagian yang benar-benar tanpa preseden.**

Ketiga proyek acuan (ios-sweet, HackiOS, UniXNU) memakai **GICv3**, karena
SoC mereka memang punya GICv3. MSM8953 punya **GIC-400 = GICv2**. XNU 8020
sendiri hanya punya dua jalur: Apple **AIC**, dan **GICv3** (`HAS_GIC_V3`,
hanya untuk `VMAPPLE`). Untuk board non-GICv3, `pe_init_fiq()` di source
asli kosong dan `sleh_irq()` memakai system register GICv3
(`ICC_IAR0_EL1`/`ICC_EOIR0_EL1`) yang tidak ada di GICv2.

Karena itu patch 0003 (driver GIC-400 + jalur ack/EOI MMIO) adalah **karya
orisinil, bukan hasil menyalin dari proyek mana pun**. Ini bagian yang paling
mungkin butuh iterasi di hardware, dan yang paling sulit dicocokkan dengan
pengalaman orang lain.

## Yang belum kita kerjakan

Diurutkan menurut dampak:

| # | Item | Rujukan |
|---|---|---|
| 1 | **Shim** — kode yang menerima kendali dari ABL, menyiapkan MMU, lalu melompat ke `_start` XNU | `shim/` ios-sweet |
| 2 | **Identitas device** (`hw.product` / `hw.target` dari device tree) supaya userland iOS menerima HP-nya | patch 0059 ios-sweet |
| 3 | **Ukuran page** — ios-sweet 16 KB, UniXNU/Redmi Note 12 memakai build 4 KB | langkah 4 panduan |
| 4 | **Driver storage** (eMMC/UFS) supaya sampai "waiting for root device" | langkah 5 panduan |
| 5 | **Root image iOS** dari IPSW, ditulis ke `userdata` | `tools/mkiosroot.sh` |

## Pembagian kerja yang realistis per host

| Pekerjaan | WSL / Linux | macOS |
|---|---|---|
| Ambil + patch source XNU | ✅ | ✅ |
| Cek penanda patch, ABI `arm64`, `-mcpu=cortex-a53` | ✅ | ✅ |
| ADT (`mkadt.py`), DTB | ✅ | ✅ |
| Boot image | ✅ | ✅ |
| **Shim** (`aarch64-linux-gnu-gcc`) | ✅ | ✅ |
| Root image iOS | ✅ | – |
| **Kompilasi kernel XNU** | ❌ | ✅ |

Baris terakhir itu satu-satunya yang tidak bisa dipindahkan. Sisanya — dan
itu termasuk shim, yang saat ini jadi penghalang terbesar — bisa dikerjakan
di WSL tanpa macOS sama sekali.
