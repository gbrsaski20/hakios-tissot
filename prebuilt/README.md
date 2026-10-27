# prebuilt/

Artefak hasil build untuk Xiaomi Mi A1 (`tissot`). **Semua bisa dibuat ulang**
dari source di repo ini, dan semuanya di-*gitignore* — tidak ada yang
di-commit kecuali berkas README ini.

| Berkas | Dibuat oleh | Isi |
|--------|-------------|-----|
| `tissot.adt` | `tools/mkadt.py` | **Apple Device Tree** untuk MSM8953 (~186 KB). Inilah yang dibaca XNU lewat `boot_args.deviceTreeP`, bukan FDT Linux. Turunan ADT iPhone X + override tissot. |
| `tissot.dtb` | `tools/build_tissot_dtb.py` | FDT Linux MSM8953 (~3 KB). Dipakai sebagai *appended DTB* di dalam payload `Image.gz-dtb` supaya ABL mau menerima boot image. |
| `tissot.dts` | `tools/build_tissot_dtb.py` | Sumber FDT dalam bentuk teks (referensi alamat register). |
| `tissot-kernel-arm64.Image` | CI `xnu-tissot` **atau** `build_kernel_placeholder_arm64.py` | Kernel ARM64. Hasil CI = XNU asli. Placeholder = `wfi` spin loop untuk menguji pipeline. |
| `tissot-ramdisk.cpio.gz` | `tools/make_tissot_bootimg.py` | Ramdisk minimal (cpio newc + `/init`). Nanti diganti root iOS. |
| `tissot-boot.img` | `tools/make_tissot_bootimg.py` | **Ini yang di-flash.** Android boot image v0, page 2048, berisi kernel + ramdisk + DTB + ADT. |

## Membuat ulang semuanya

```bat
make-tissot.bat
```

Atau di Linux/macOS:

```bash
make tissot        # adt + dtb + placeholder kernel + boot.img
make check         # audit ADT terhadap 12 syarat XNU
```

## Cara tahu kernel di dalamnya asli atau placeholder

```bash
python tools/make_tissot_bootimg.py
```

Perhatikan baris `kernel check` dan ukuran `tissot-kernel-arm64.Image`:

| Ukuran | Arti |
|--------|------|
| 65.536 byte | **placeholder** (`wfi` spin loop) — hanya menguji pipeline |
| ratusan KB – beberapa MB | kemungkinan **XNU asli** hasil CI |

`tissot-boot.img` tidak di-commit (`.gitignore`), begitu juga `*.Image`.
