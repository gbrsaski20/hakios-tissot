# Legal

## What is distributed

- Source code: patch series untuk XNU di `xnu/patches-8020/` (APSL 2.0),
  build script (`xnu/apply-8020.sh`, `xnu-build-arm64.sh`), dan tool Python
  di `tools/` (rakit ADT, packer boot image, ekstraksi IPSW).
- Tidak ada binary kernel di repo. Kernel dibangun dari source Apple di CI.

## What is NOT distributed

- **Tidak ada berkas iOS**: tidak ada binary, image, dyld cache, font, gambar,
  atau berkas iOS apa pun. Kamu mengambil sendiri IPSW iOS 15.6.1 (19G82) dari
  server publik Apple, lalu `tools/extract_adt.py` mengekstrak DeviceTree-nya
  tanpa mendekripsi atau mengakali apa pun.
- **Tidak ada firmware**: `boot.img` stock Mi A1 dan DTB-nya milik Xiaomi.
  Kamu menyediakannya sendiri (dari firmware yang kamu punya).
- **Tidak ada key, sertifikat, activation**: tidak ada yang membuat perangkat
  lolos sebagai iPhone ke layanan Apple. Login akun Apple tidak mungkin di
  sini dan bukan tujuan.

## Licenses

- Patch XNU: **Apple Public Source License 2.0** (APSL 2.0). Apple menerbitkan
  XNU dengan lisensi itu. Syaratnya dipenuhi: perubahan dipublikasikan sebagai
  source, notices dipertahankan.
- Kode proyek ini (tool Python, script build, patch driver): lihat header
  masing-masing berkas. Default: APSL 2.0 untuk berkas kernel yang merupakan
  turunan XNU, MIT untuk kode standalone.
- Komponen pihak ketiga: lihat `THIRD_PARTY_LICENSES.md`.

## Trademarks

"iOS", "iPhone", "XNU", "Apple", dan merek dagang lain yang disebut adalah
milik pemiliknya masing-masing. Disebut hanya untuk menjelaskan apa yang
dikerjakan kode ini. HakiOS **tidak berafiliasi dengan atau didukung Apple**.

## Not legal advice

Informasi di berkas ini, `COMPLIANCE.md`, `THIRD_PARTY_LICENSES.md`, dan
`NOTICE` hanya untuk tujuan informasi dan bukan nasihat hukum.
