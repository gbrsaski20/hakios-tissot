# tools/ — Xiaomi Mi A1 (`tissot`)

Semua tool di sini **Python murni**. Tidak butuh compiler, `mkbootimg`, `dtc`,
WSL, atau macOS. Yang butuh macOS hanya build kernel XNU itu sendiri
(`xnu-build-arm64.sh`, dijalankan di CI).

| Script | Fungsi |
|--------|--------|
| `mkadt.py` | **Apple Device Tree** — parse/serialize/edit format DT milik Apple (bukan FDT), plus preset `--tissot` dan audit syarat XNU |
| `extract_adt.py` | Ambil `DeviceTree.d22ap.im4p` dari IPSW iOS 15.6.1 lalu decompress LZFSE |
| `build_tissot_dtb.py` | FDT Linux MSM8953 (referensi alamat register, dipakai sebagai appended DTB) |
| `make_tissot_bootimg.py` | Packer Android boot image v0 (kernel + ramdisk + DTB + ADT) dengan verifikasi |
| `build_kernel_placeholder_arm64.py` | Kernel ARM64 placeholder (`wfi` spin loop) untuk menguji pipeline tanpa build XNU |

## Alur

```
IPSW iOS 15.6.1
   │  extract_adt.py
   ▼
DeviceTree.d22ap.im4p → d22ap_15.6.1.adt
   │  mkadt.py --tissot          (override MSM8953 + audit 12 cek)
   ▼
prebuilt/tissot.adt

build_tissot_dtb.py ──► prebuilt/tissot.dtb
build_kernel_placeholder_arm64.py ──► prebuilt/tissot-kernel-arm64.Image
   │
   ▼  make_tissot_bootimg.py
prebuilt/tissot-boot.img   ← fastboot boot
```

## mkadt.py

XNU **tidak** memakai FDT Linux. Ia memakai format Device Tree milik Apple
(`struct DeviceTreeNode`, little-endian, lihat `pexpert/pexpert/device_tree.h`).

```bash
# lihat isi ADT asli
python tools/mkadt.py --template devices/tissot/dt/d22ap_15.6.1.adt --info

# buktikan writer-nya benar (parse -> tulis ulang harus byte-identik)
python tools/mkadt.py --template devices/tissot/dt/d22ap_15.6.1.adt --roundtrip

# rakit ADT tissot + audit syarat XNU
python tools/mkadt.py --template devices/tissot/dt/d22ap_15.6.1.adt \
                       --tissot --out prebuilt/tissot.adt
```

Yang ditimpa preset `--tissot`:

| Node | Jadi | Dipakai oleh |
|------|------|--------------|
| `/arm-io:ranges` | parent `0x07800000` | `pe_arm_get_soc_base_phys()` |
| `/arm-io/serial:reg` | `0xAF000` → phys `0x78AF000` | `serial_init()` |
| `/arm-io/aic` → `/arm-io/gic` | GICD `0x0B000000`, GICC `0x0B002000` | `pe_init_fiq()` (GICv2) |
| `/arm-io/aic-timebase` → `/arm-io/gic-timebase` | `device_type=timer` | `pe_arm_map_interrupt_controller()` |
| `/cpus/cpuN:*frequency*` | 19,2 MHz dst | `pe_identify_machine()` |
| `/memory:reg` | `0x80000000` + 4 GiB | `arm_vm_init()` |

Dua hal yang mudah salah dan sudah ditangani:

1. **Node AIC harus dihapus.** `SecureDTFindEntry` itu *first-match*, jadi kalau
   AIC Apple masih ada XNU akan memetakan register AIC di `0x32100000`.
2. **Frekuensi `/cpus` harus diisi.** ADT iPhone X melaporkan `0` untuk semua
   frekuensi, dan `timebase-frequency = 0` membuat `bus_to_dec_rate_den`
   membagi nol di `pe_identify_machine.c:177`.

Audit di akhir keluaran (`XNU 8020 requirement audit`) mencetak 12 cek; script
keluar dengan kode 1 kalau ada yang gagal.

## wsl-check.sh

```bash
bash tools/wsl-check.sh              # unduh source + apply patch + semua cek
bash tools/wsl-check.sh --no-fetch   # kalau xnu-src-8020 sudah ada
```

Mereproduksi job `patches` dari CI di WSL/Linux, supaya iterasi patch tidak
perlu menunggu runner macOS. Memeriksa: tool yang dibutuhkan, CRLF pada
skrip, patch 0001..0008 apply bersih, 17 penanda patch, TISSOT -> `arm64`
(bukan `arm64e`), `-mcpu=cortex-a53`, lalu rakit ADT + DTB + boot image.

Dia **tidak** mengompilasi kernel dan tidak berpura-pura bisa: XNU butuh
clang + cctools + SDK Apple di macOS. Bagian 6 skrip ini menjelaskan itu.

## wsl-build.sh

```bash
bash tools/wsl-build.sh                  # seluruh pipeline lokal
bash tools/wsl-build.sh --check          # laporan toolchain saja
bash tools/wsl-build.sh --no-compile     # patch + image, tanpa kompilasi
bash tools/wsl-build.sh --sdk /path/iPhoneOS.sdk
```

Satu perintah untuk semua yang bisa dikerjakan di WSL: cek lingkungan,
`apply-8020.sh`, cek ABI (`arm64`, bukan `arm64e`), `mkadt.py`,
`build_tissot_dtb.py`, kompilasi (kalau toolchain ada), lalu boot image.

Kode keluar membedakan dua hal yang penting:

| kode | arti |
|------|------|
| `0` | semua langkah berhasil, termasuk kompilasi |
| `1` | ada langkah yang gagal — biasanya patch atau image |
| `3` | pipeline lokal beres, **kompilasi** yang belum bisa: toolchain Mach-O tidak ada |

Kalau toolchain lengkap (macOS, atau Linux dengan `ld64` + `ctf_insert` +
`kextsymboltool` + SDK iPhoneOS), skrip memasang shim `xcrun` sementara lalu
memanggil `xnu-build-arm64.sh`, sehingga makefile XNU bisa jalan di luar
macOS.

## make_tissot_bootimg.py

```bash
python tools/make_tissot_bootimg.py
python tools/make_tissot_bootimg.py --kernel X --dtb Y --adt Z --out W
python tools/make_tissot_bootimg.py --kernel-format raw
python tools/make_tissot_bootimg.py --adt ""            # tanpa ADT
python tools/make_tissot_bootimg.py --allow-foreign-kernel
```

Format default `gz-dtb` = `gzip(Image) + DTB` sebagai satu payload, sama
seperti `boot.img` stock tissot (`BOARD_KERNEL_IMAGE_NAME := Image.gz-dtb`).
Mode `raw` menaruh Image apa adanya dan DTB sebagai section terpisah.

ADT Apple ditambahkan sebagai section ke-4 (ekstensi kita). Alamat fisiknya
dicetak — itulah nilai untuk `boot_args.deviceTreeP` yang harus diisi SHIM.
Kalau file ADT tidak ada, section itu dilewati (dengan pesan), bukan gagal.

`--allow-foreign-kernel` menerima payload yang bukan arm64 Image — dipakai CI
untuk mengemas kernel XNU hasil build, yang berupa **Mach-O**. Tanpa flag itu
Mach-O ditolak, karena memang tidak bisa di-boot: ABL melompat ke offset 0
payload dan header Mach-O bukan kode. Itu urusan SHIM.

Setelah menulis, script mem-parse ulang image-nya sendiri dan memverifikasi:
magic `ANDROID!`, SHA-1 header, magic `ARM\x64` di kernel (atau Mach-O kalau
flag di atas dipakai), magic FDT di DTB, gzip di ramdisk, dan ADT
**byte-identik** dengan sumbernya.
