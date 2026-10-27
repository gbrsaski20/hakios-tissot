# Port XNU 8020 (iOS 15) ke Xiaomi Mi A1 — status & rencana

Dokumen ini mencatat apa yang **sudah benar-benar dikerjakan** untuk port  
`xnu-8020` ke tissot (MSM8953 / Cortex-A53), apa yang **belum**, dan di  
file mana persisnya pekerjaan berikutnya.

Basis: **`xnu-8020.140.41`** — satu-satunya rangkaian 8020 yang dipublikasikan  
Apple (hanya ada 3 tag: `.101.4`, `.121.3`, `.140.41`).

---

## 1. Status ringkas

| Item                                  | Status                                 |
| ------------------------------------- | -------------------------------------- |
| Source XNU 8020 diunduh & diekstrak   | ✅ `xnu-src-8020/` (4.851 file)         |
| Board config **TISSOT** dibuat        | ✅ `pexpert/pexpert/arm64/TISSOT.h`     |
| Patch series dibuat & **diuji apply** | ✅ `xnu/patches-8020/0001-…patch`       |
| Script fetch + apply                  | ✅ `xnu/apply-8020.sh`                  |
| Script build + cek toolchain          | ✅ `xnu-build-arm64.sh` (+ `--force`)   |
| Patch 0002 — driver UART console      | ✅ **draft**, apply teruji (compile TBD)|
| **Build kernel sungguhan**            | ❌ butuh macOS + cctools + SDK          |
| UART benar-benar keluar log           | ❌ butuh ADT (`mkadt.py`) + hardware    |
| Platform identify / ADT               | ❌ belum                                |
| SHIM + mkpayload                      | ❌ belum                                |

---

## 2. Temuan terverifikasi di dalam source

Semua di bawah ini dicek langsung di `xnu-src-8020/`, bukan asumsi.

### 2.1 ARM64 selalu jadi `arm64e` (PAC) — ini blocker nomor satu

`makedefs/MakeInc.def:250-252`:

```make
ifneq ($(filter ARM64,$(CURRENT_ARCH_CONFIG)),)
export ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG := arm64e
endif
```

Kalau `EMBEDDED_DEVICE_MAP` tidak ada (kasus kita), **semua** build ARM64  
dipaksa `arm64e` = ABI dengan Pointer Authentication. Cortex-A53 **tidak punya  
PAC**, jadi kernel hasilnya tidak akan jalan.

→ Dipatch: khusus `CURRENT_MACHINE_CONFIG=TISSOT`, pakai `arm64`.

### 2.2 Flag CPU Apple tidak mungkin jalan di A53

`makedefs/MakeInc.def:62-65`:

```make
MACHINE_FLAGS_ARM64_T8101  = -DARM64_BOARD_CONFIG_T8101_T8103  -mcpu=apple-a14
MACHINE_FLAGS_ARM64_T6000  = -DARM64_BOARD_CONFIG_T6000        -mcpu=apple-a14
MACHINE_FLAGS_ARM64_VMAPPLE= -DARM64_BOARD_CONFIG_VMAPPLE      -march=armv8.5a
MACHINE_FLAGS_ARM64_BCM2837= -DARM64_BOARD_CONFIG_BCM2837
```

→ Ditambah `MACHINE_FLAGS_ARM64_TISSOT = -DARM64_BOARD_CONFIG_TISSOT -mcpu=cortex-a53`.

### 2.3 Preseden ARMv8.0 sudah ada: BCM2837

`BCM2837` = Raspberry Pi 3 = **Cortex-A53, ARMv8.0** — sama kelasnya dengan  
MSM8953. Board config-nya (`pexpert/pexpert/arm64/BCM2837.h`) jadi cetak biru  
`TISSOT.h`. Ini bukti bahwa XNU 8020 memang bisa ditargetkan ke ARMv8.0.

### 2.4 Tidak ada LSE atomics / FP16 di source

Hasil scan `xnu-src-8020/`:

| Pola                                                                   | Hasil       |
| ---------------------------------------------------------------------- | ----------- |
| `__ARM_FEATURE_ATOMICS` / `__ARM_FEATURE_FP16` / `__ARM_FEATURE_CRC32` | **0 match** |
| instruksi LSE di asm (`casal`, `ldaddal`, `stsetal`, `swpal`, …)       | **0 match** |

Artinya selama dikompilasi dengan `-mcpu=cortex-a53` (tanpa `+lse`), compiler  
tidak akan menghasilkan instruksi ARMv8.1. Ini **mendukung** kesimpulan  
`docs/IOS15-VS-IOS16-ARMv8.md`.

### 2.5 XNU tidak punya kode Qualcomm sama sekali

`grep -rli "qualcomm\|msm8953"` → hanya mengenai file TISSOT yang baru dibuat.  
Jadi seluruh lapisan platform harus ditulis sendiri.

### 2.6 Titik-titik integrasi platform (hasil pencarian)

| Kebutuhan                | File                                                  | Catatan                                                 |
| ------------------------ | ----------------------------------------------------- | ------------------------------------------------------- |
| Console UART             | `pexpert/arm/pe_serial.c:567`                         | blok `#ifdef PI3_UART` → tiru jadi `#ifdef TISSOT_UART` |
| `uart_ops` registration  | `pexpert/arm/pe_serial.c:324,408`                     | `.init = …` per platform                                |
| Console init             | `pexpert/arm/pe_init.c:180` `PE_initialize_console()` | dipanggil di `:501-503`                                 |
| Identifikasi mesin / ADT | `pexpert/arm/pe_identify_machine.c` (630 baris)       | di sini XNU membaca Apple Device Tree                   |
| Pembaca DT               | `pexpert/gen/device_tree.c` (554 baris)               | `DTGetProperty`                                         |
| Boot args                | `pexpert/gen/bootargs.c`                              | `PE_parse_boot_argn`                                    |

---

## 3. Patch 0001 — apa isinya

`xnu/patches-8020/0001-add-tissot-board-config.patch` (122 baris, 3 file):

1. `makedefs/MakeInc.def`
   - `SUPPORTED_ARM64_MACHINE_CONFIGS` += `TISSOT`
   - `MACHINE_FLAGS_ARM64_TISSOT = -DARM64_BOARD_CONFIG_TISSOT -mcpu=cortex-a53`
   - `ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG := arm64` (khusus TISSOT)
2. `pexpert/pexpert/arm64/board_config.h`
   - blok `#ifdef ARM64_BOARD_CONFIG_TISSOT`: `MAX_L2_CLINE 6`, `MAX_CPUS 8`,  
     `MAX_CPU_CLUSTERS 1`, `CORE_NCTRS 8`
3. `pexpert/pexpert/arm64/TISSOT.h` (baru, 58 baris)
   - `NO_MONITOR`, `NO_ECORE`, `ARM_ARCH_TIMER`, `__ARM_ARCH__ 8`,  
     `__ARM_VMSA__ 8`, `__ARM_COHERENT_CACHE__ 1`, `__ARM64_PMAP_SUBPAGE_L1__ 1`
   - UART console `0x078AF000` (ttyHSL0)

**Verifikasi yang dilakukan:** patch di-`patch -p1 --dry-run` ke salinan  
pristine dari tag yang sama → bersih; lalu di-apply sungguhan dan hasilnya  
`diff` **byte-identik** dengan file yang diedit manual.

---

## 4. Yang masih harus ditulis (urutan yang disarankan)

### Patch 0002 — UART console tissot ✅ (draft, sudah ditulis)

`xnu/patches-8020/0002-tissot-uart-console.patch` — 154 baris, 5 hunk, 3 file:

| File | Perubahan |
|------|-----------|
| `pexpert/pexpert/arm/protos.h` | `SERIAL_TISSOT_UART=0x20` di `serial_device_t` |
| `pexpert/pexpert/arm64/TISSOT.h` | offset register UARTDM (`MR/IPR/SR/CR/RF/TF`) + bit `SR`/`CR` |
| `pexpert/arm/pe_serial.c` | blok driver `tissot_uart_{tr0,td0,rr0,rd0,init}` + `tissot_uart_serial_functions`, dan hook di `serial_init()` |

Desain penting: `init()` **tidak** memprogram ulang baud rate. Bootloader (ABL)
sudah menyetel `console=ttyHSL0,115200,n8`, jadi `init()` hanya menyalakan
transmitter (`UARTDM_CR` bit TX/RX enable). Ini menghindari merusak konsol
yang sudah hidup.

**Verifikasi yang dilakukan:** komposisi `pristine → 0001 → 0002` diuji di
direktori bersih; kelima file hasilnya **byte-identik** dengan tree kerja.

**Batasan draft ini:**
- Belum pernah dikompilasi (tidak ada clang/cctools di sini).
- Belum jalan tanpa ADT: hook memanggil `SecureDTFindEntry("name","serial")`
  dan butuh `arm-io` + `ranges` supaya `pe_arm_get_soc_base_phys()` ≠ 0.
  Keduanya bergantung pada `mkadt.py` yang **belum ada**.
- Offset register mengikuti `msm_serial_hs.c`; wajib diverifikasi di hardware.

### Patch 0003 — `pe_identify_machine.c` untuk TISSOT

Tanpa Apple's `machine_info`/ADT yang sesuai, XNU akan gagal mengidentifikasi  
platform. Ini bagian yang paling banyak "trial and error".

### Patch 0004 — load address

`ARM64_LINK_ADDR` harus cocok dengan tempat bootloader menaruh kernel  
(`0x80008000` untuk tissot, dari `BOARD_KERNEL_BASE 0x80000000` + offset).

### Belum tersentuh sama sekali

- `mkadt.py` (Apple Device Tree untuk MSM8953)
- `mkpayload.py` (kernel + ADT + boot-args → payload)
- `shim/` (bare-metal C+asm antara ABL dan XNU)
- `mkiosroot.sh` (root iOS 15.6.1 → HFS+)

---

## 5. Cara build (dan kenapa tidak bisa di sini)

XNU butuh **clang + cctools (ld, ctf_insert, kextsymboltool) + SDK Apple**,  
dan build system-nya berjalan di **macOS**. Di mesin Windows ini semuanya  
tidak ada — `./xnu-build-arm64.sh --check` akan melaporkan:

```
clang  : MISSING
ld : MISSING (part of Apple cctools)
ctf_insert : MISSING
kextsymboltool : MISSING
make   : MISSING
SDKROOT: not set
host   : MINGW64 — XNU builds on macOS only
```

**Jalur yang disarankan (sama seperti ios-sweet):** GitHub Actions runner  
`macos-latest` (gratis untuk repo publik).

Perintah `make` yang **benar** (terverifikasi di `makedefs/MakeInc.cmd:143-151`):

```
make ARCH_CONFIGS=ARM64 KERNEL_CONFIGS=DEVELOPMENT \
     CURRENT_MACHINE_CONFIG=TISSOT SDKROOT=iphoneos
```

Kenapa `SDKROOT=iphoneos` dan **bukan** path SDK macOS: `PLATFORM` diturunkan
dari `xcrun -sdk $(SDKROOT) -show-sdk-platform-path`. Memberi SDK macOS membuat
`PLATFORM=MacOSX` → yang dibangun kernel ARM64-macOS, bukan iPhoneOS. Jangan
memberi `PLATFORM` manual: nilainya harus *undefined* agar derivasi itu jalan.

```yaml
# .github/workflows/xnu-tissot.yml (kerangka)
jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./xnu/apply-8020.sh
      - run: ./xnu-build-arm64.sh --config DEVELOPMENT --jobs 4
      - uses: actions/upload-artifact@v4
        with:
          name: xnu-tissot
          path: prebuilt/tissot-kernel-arm64.Image
```

Setelah kernel jadi:

```bash
./devices/tissot/build-bootimage.sh --kernel prebuilt/tissot-kernel-arm64.Image
fastboot boot prebuilt/tissot-boot.img
```

---

## 6. Checklist

- [x] Tentukan versi: `xnu-8020.140.41`
- [x] Unduh + ekstrak source
- [x] Board config TISSOT (arm64, bukan arm64e; `-mcpu=cortex-a53`)
- [x] Patch 0001 dibuat & teruji apply
- [x] Script fetch/apply & build-driver + cek toolchain
- [x] Patch 0002 — UART console tissot (draft, apply teruji)
- [ ] Patch 0003 — platform identify (ADT)
- [ ] Patch 0004 — ARM64_LINK_ADDR
- [ ] CI macOS → kernel pertama
- [ ] `mkadt.py` untuk MSM8953
- [ ] `shim/` untuk tissot
- [ ] `mkiosroot.sh` dari IPSW 15.6.1
- [ ] Boot pertama + baca log via UART

---

## 7. Catatan jujur

Yang sudah ada sekarang adalah **fondasi yang benar dan terverifikasi** —  
bukan kernel yang bisa boot. Tiga pekerjaan terbesar yang tersisa (UART,  
platform identify/ADT, dan SHIM) adalah kerja rendah-level yang butuh  
perangkat fisik untuk iterasi. Tanpa Mi A1 + bootloader unlocked + akses  
UART, kemajuannya akan sangat lambat.

Risiko ARMv8.0 sendiri sudah jauh berkurang karena memakai iOS 15  
(lihat `docs/IOS15-VS-IOS16-ARMv8.md`), dan source-nya terbukti bebas  
instruksi LSE/FP16.
