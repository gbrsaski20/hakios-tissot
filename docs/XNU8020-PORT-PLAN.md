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
| Patch 0003 — **driver GICv2 (GIC-400)** | ✅ **draft**, apply teruji (compile TBD)|
| **Build kernel sungguhan**            | ❌ butuh macOS + cctools + SDK          |
| UART benar-benar keluar log           | ❌ butuh hardware                      |
| Interrupt/timer benar-benar jalan     | ❌ butuh hardware                      |
| `mkadt.py` (Apple Device Tree)        | ✅ round-trip byte-identik, preset ok   |
| ADT memuat **GIC + timer + frekuensi** | ✅ 12/12 audit lulus (`--tissot`)       |
| Platform identify / ADT               | ✅ ADT lengkap untuk semua call-site XNU|
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

### 2.7 Format ADT — ditemukan & dibuktikan

XNU **tidak** memakai FDT. Formatnya ada di `pexpert/pexpert/device_tree.h`:

```c
struct DeviceTreeNode {              // little-endian
    uint32_t nProperties;
    uint32_t nChildren;
    DeviceTreeNodeProperty props[nProperties];
    DeviceTreeNode         children[nChildren];   // rekursif
};
struct DeviceTreeNodeProperty {
    char     name[32];               // NUL-padded
    uint32_t length;                 // panjang asli = value & 0x7FFFFFFF
    uint8_t  value[length];          // di-pad ke 4 byte
};
```

Dua hal yang **tidak** tertulis di header dan hanya ketemu secara empiris
(dari ADT asli d22ap iOS 15.6.1):

1. Field `length` memakai **bit atas `0x80000000` sebagai flag**. 89 dari 3.363
   properti memakainya (semuanya bertipe referensi `syscfg/...`). Flag ini
   **harus dipertahankan per-properti**, kalau tidak, ADT hasil tulis berbeda
   dari aslinya.
2. Seluruh field **little-endian** (bukan big-endian seperti FDT).

Bukti: `python tools/mkadt.py --roundtrip` → parse lalu tulis ulang
**byte-identik** dengan 185.188 byte asli.

### 2.8 Bagaimana `serial_init()` menemukan UART

`pe_arm_get_soc_base_phys()` (`pe_identify_machine.c:181-201`):

```c
SecureDTGetProperty(entryP, "ranges", &ranges_prop, &prop_size);
gPESoCBasePhys = *(ranges_prop + 1);   // word ke-2 (uintptr_t = 8 byte)
```

lalu `serial_init()` melakukan `ml_io_map(soc_base + *reg_prop, *(reg_prop+1))`
dan **berhenti lebih awal kalau `soc_base == 0`**.

Konsekuensinya untuk tissot: `ranges` harus punya parent **bukan nol**.
`mkadt.py` memakai `ranges = {0, 0x07800000, 0x10000000}` dan `serial.reg =
{0xAF000, 0x200}` → `0x07800000 + 0xAF000 = 0x78AF000` (UART console asli).

### 2.9 XNU tidak punya driver GICv2 — ini blocker nomor dua

Ini temuan yang paling menentukan bentuk patch 0003. XNU 8020 hanya punya
**dua** jalur interrupt controller:

| Jalur | Di mana | Untuk siapa |
|-------|---------|-------------|
| **Apple AIC** | `pexpert/pexpert/arm64/AIC.h`, dipakai `pe_arm_init_timer()` | SoC Apple |
| **GICv3** | `pexpert/arm/pe_fiq.c` blok `#if HAS_GIC_V3` | **hanya** VMAPPLE (`HAS_GIC_V3` cuma didefinisikan di `VMAPPLE.h`) |

MSM8953 memakai **GIC-400 = GICv2**, dan untuk build non-GICv3
`pe_init_fiq()` di source asli **kosong total**:

```c
#else
void
pe_init_fiq()
{
}
#endif
```

Artinya tanpa patch, kernel tissot: keluar beberapa baris ke UART → lalu
**hang selamanya** karena tidak pernah menerima interrupt timer. Scheduler
tidak pernah tick, `rtclock` tidak pernah maju.

Selain itu `sleh_irq()` di `osfmk/arm64/sleh.c:1902,1949` memakai
**system register GICv3** (`ICC_IAR0_EL1` / `ICC_EOIR0_EL1`) — dan itu pun
di dalam `#if APPLEVIRTUALPLATFORM`. GICv2 memakai **MMIO**
(`GICC_IAR` / `GICC_EOIR`), jadi jalur ack/EOI juga harus ditambah.

→ Patch 0003 menambahkan driver GICv2 penuh + jalur ack/EOI MMIO.

### 2.10 `/cpus` di ADT iPhone X: `state=running` tapi semua frekuensi 0

`pe_identify_machine()` melewati CPU yang `state`-nya bukan `running`, lalu
membaca `timebase-frequency`, `bus-frequency`, `clock-frequency`, dst.

ADT d22ap asli:

```
cpu0  state=running   timebase-frequency=0  clock-frequency=0  ...
cpu1..5 state=waiting
```

Dua hal penting:

1. **Semua frekuensi 0.** `timebase_frequency_hz = 0` → `dec_clock_rate_hz = 0`
   → `bus_to_dec_rate_den = bus_clock_rate_hz / 0` = **bagi nol** di
   `pe_identify_machine.c:177`. Jadi frekuensi **wajib** diisi (19,2 MHz untuk
   MSM8953).
2. **Hanya cpu0 `running`.** Ini justru **menguntungkan**: XNU hanya akan
   membawa CPU 0. Bring-up single-core adalah target pertama yang benar, dan
   MSM8953 memang butuh PSCI/spin-table untuk core kedua yang belum kita
   implementasikan. Tidak perlu diubah dulu.

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

### Patch 0003 — driver GICv2 (GIC-400) ✅ (draft, sudah ditulis)

`xnu/patches-8020/0003-tissot-gicv2-interrupts.patch` — 451 baris, 7 hunk,
4 file:

| File | Perubahan |
|------|-----------|
| `pexpert/pexpert/arm64/TISSOT.h` | `TISSOT_GIC_V2`, alamat GICD/GICC, offset register GICD/GICC lengkap, bit `CTLR`, INTID timer PPI 26/27, prioritas default |
| `pexpert/pexpert/arm/protos.h` | prototipe `pe_gic_ack_irq()` / `pe_gic_eoi_irq()` (di sini karena `sleh.c` sudah meng-include header ini) |
| `pexpert/arm/pe_fiq.c` | blok `#elif defined(ARM64_BOARD_CONFIG_TISSOT)` — driver penuh: map GICD+GICC dari ADT, inisialisasi distributor (group, prioritas, target, level-trigger), inisialisasi CPU interface per-core, aktifkan PPI timer |
| `osfmk/arm64/sleh.c` | cabang `#elif … TISSOT` di dua tempat: `GICC_IAR` untuk ack, `GICC_EOIR` untuk EOI (menggantikan `ICC_*_EL1` yang tidak ada di GICv2) |

**Verifikasi yang dilakukan:** komposisi `pristine → 0001 → 0002 → 0003`
diuji di direktori bersih; **ketujuh** file hasilnya byte-identik dengan tree
kerja. Kurung `{}`/`()` di `pe_fiq.c`, `TISSOT.h`, `protos.h` seimbang
(`sleh.c` punya selisih 1 kurung yang **sudah ada di source Apple asli** —
929/928 → 936/935, patch menambah 7 pasang).

**Batasan draft ini:**
- Belum pernah dikompilasi (tidak ada clang/cctools di sini).
- **Group 0 vs group 1**: group 0 adalah grup FIQ dan normalnya secure-only.
  Android boot di non-secure world, jadi di hardware asli tulis ke
  `GICD_IGROUPR` bisa read-back sebagai group 1 dan `GICC_CTLR` bit 0 bisa
  RAZ/WI. Kalau itu terjadi, ubah `TISSOT_GIC_GROUP1` → 1 di `pe_fiq.c`
  (dan `GICC_CTLR` ke bit 1). **Ini hal pertama yang harus dicek di HP.**
- Offset register mengikuti spesifikasi ARM GICv2 + binding Linux
  `msm-qgic2`; wajib diverifikasi di hardware.

### Patch 0004 — load address / SHIM

`ARM64_LINK_ADDR` di `MakeInc.def` adalah **alamat virtual** high-half
(`0xfffffff007004000`), sama untuk semua target ARM64 XNU — jadi **tidak**
perlu diubah. Yang perlu dibuat adalah **SHIM**: kode bare-metal yang
menerima kendali dari ABL, menyiapkan page table, memetakan image kernel
fisik (`0x80008000`) ke alamat virtual itu, lalu melompat ke `_start`.

### Belum tersentuh sama sekali

- `mkpayload.py` (kernel + ADT + boot-args → payload SHIM)
- `shim/` (bare-metal C+asm antara ABL dan XNU) ← **pekerjaan terbesar berikutnya**
- `mkiosroot.sh` (root iOS 15.6.1 → HFS+)
- PSCI / spin-table untuk membawa CPU 1..7

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
- [x] `mkadt.py` untuk MSM8953 (template + override, round-trip terbukti)
- [x] Patch 0003 — **driver GICv2 (GIC-400)** + ack/EOI MMIO (draft, apply teruji)
- [x] ADT memuat `/arm-io/gic`, `/arm-io/gic-timebase`, frekuensi `/cpus` (audit 12/12)
- [ ] CI macOS → kernel pertama  ← **langkah berikutnya yang bisa dikerjakan tanpa hardware**
- [ ] `shim/` untuk tissot (map kernel fisik → VA `0xfffffff007004000`)
- [ ] `mkpayload.py` (kernel + ADT + boot-args → payload)
- [ ] Verifikasi group 0 vs group 1 GIC di hardware
- [ ] `mkiosroot.sh` dari IPSW 15.6.1
- [ ] PSCI / spin-table untuk CPU 1..7
- [ ] Boot pertama + baca log via UART

---

## 7. Catatan jujur

Yang sudah ada sekarang adalah **fondasi yang benar dan terverifikasi** —
bukan kernel yang bisa boot. Semua jalur yang dibutuhkan XNU untuk mencapai
`rtclock` sudah tertutup di sisi source: **UART** (patch 0002), **interrupt
controller + timer** (patch 0003), **device tree** (`mkadt.py`), dan
**boot image** (`make_tissot_bootimg.py`).

Yang masih menghalangi, berurutan menurut besar-kecilnya:

1. **SHIM** — belum ada kode yang menyambut kendali dari ABL dan menyiapkan
   MMU/page table sebelum melompat ke `_start` XNU. Tanpa ini kernel tidak
   akan pernah dieksekusi.
2. **Build kernel di macOS** — patch 0001–0005 baru mencapai tahap kompilasi.
   Error compiler pertama akan menjadi petunjuk patch berikutnya.
3. **Verifikasi hardware** — group 0/1 GIC dan offset register UART hanya
   bisa dipastikan di Mi A1 asli.

Risiko ARMv8.0 sendiri sudah jauh berkurang karena memakai iOS 15
(lihat `docs/IOS15-VS-IOS16-ARMv8.md`), dan source-nya terbukti bebas
instruksi LSE/FP16.
