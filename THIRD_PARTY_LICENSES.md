# Third-Party Licenses

Proyek ini menargetkan Xiaomi Mi A1 (`tissot`). Yang di-*link*/dipakai saat
build maupun saat menjalankan tool:

## XNU Kernel
- **Origin**: Apple Inc. (https://github.com/apple-oss-distributions/xnu)
- **License**: Apple Public Source License 2.0 (APSL 2.0)
- **Used in**: `xnu/patches-8020/` (patch series adalah derivative work)
- **Version**: `xnu-8020.140.41` (generasi iOS 15)
- **Catatan**: source-nya **tidak** di-commit; `xnu/apply-8020.sh` mengunduhnya
  saat build.

## Clang / LLVM
- **Origin**: LLVM Project (https://llvm.org)
- **License**: Apache 2.0 with LLVM exceptions
- **Used in**: Building the kernel (lewat Xcode di runner macOS)
- **Catatan**: disediakan oleh toolchain Xcode, tidak didistribusikan repo ini.

## Apple cctools (ld64, ctf_insert, kextsymboltool)
- **Origin**: Apple Inc. (bagian dari Xcode toolchain)
- **License**: APSL 2.0 / Apple SDK agreement
- **Used in**: Linking the kernel
- **Catatan**: tidak didistribusikan; tersedia di macOS runner GitHub Actions.

## lzfse
- **Origin**: Apple Inc. (https://github.com/lzfse/lzfse)
- **License**: BSD-3-Clause
- **Used in**: `tools/extract_adt.py` — decompress payload `DeviceTree.d22ap.im4p`
- **Catatan**: paket Python `lzfse` (opsional; script tetap jalan tanpa itu
  untuk ekstraksi `.im4p` mentah).

## Python standard library
- **Origin**: Python Software Foundation
- **License**: PSF License
- **Used in**: semua tool di `tools/` (hanya `struct`, `gzip`, `hashlib`,
  `zlib`, `argparse`, `os`, `sys`, `io`)

## GitHub Actions (runner)
- **Origin**: GitHub / Microsoft
- **License**: GitHub Terms of Service
- **Used in**: `.github/workflows/xnu-tissot.yml`
- **Catatan**: `actions/checkout` dan `actions/upload-artifact` (MIT).

---

## Yang TIDAK didistribusikan repo ini

| Item | Pemilik | Kenapa tidak ada |
|------|---------|------------------|
| IPSW iOS 15.6.1 | Apple | kamu unduh sendiri dari Apple CDN |
| `boot.img` / DTB stock Mi A1 | Xiaomi | dari firmware milikmu sendiri |
| XNU source | Apple | diunduh `apply-8020.sh` saat build |
| Apple SDK / cctools | Apple | disediakan runner macOS |
| ADT hasil ekstraksi | turunan IPSW | di-*gitignore*, dibuat lokal oleh `mkadt.py` |
