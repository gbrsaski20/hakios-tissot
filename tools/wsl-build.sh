#!/bin/bash
# ============================================================================
# tools/wsl-build.sh — bangun kernel XNU TISSOT dari dalam WSL/Linux.
#
# Satu perintah untuk seluruh pipeline lokal:
#
#   1. cek lingkungan + toolchain
#   2. unduh XNU 8020 (kalau belum ada) dan terapkan patch 0001..0008
#   3. verifikasi penanda patch + ABI (arm64, bukan arm64e)
#   4. rakit ADT + DTB + boot image
#   5. kompilasi kernel  <- hanya jalan kalau toolchain Mach-O tersedia
#
# Pemakaian:
#   bash tools/wsl-build.sh              # semua langkah
#   bash tools/wsl-build.sh --check      # laporan toolchain saja
#   bash tools/wsl-build.sh --no-compile # lewati kompilasi
#   bash tools/wsl-build.sh --sdk /path/to/iPhoneOS.sdk
#
# Kode keluar:
#   0  semua langkah yang bisa dikerjakan di sini berhasil
#   1  ada langkah yang gagal (bukan soal toolchain)
#   3  pipeline lokal beres, tapi kompilasi butuh toolchain Mach-O yang
#      tidak ada — ini BUKAN kegagalan patch
# ============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/xnu-src-8020"
BUILD="$ROOT/xnu-build-arm64.sh"

SDK_ARG=""
DO_CHECK=0
DO_COMPILE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --check)       DO_CHECK=1 ;;
        --no-compile)  DO_COMPILE=0 ;;
        --sdk)         SDK_ARG="${2:-}"; shift ;;
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "argumen tidak dikenal: $1" >&2; exit 1 ;;
    esac
    shift
done

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
YEL=$'\033[33m'; CYA=$'\033[36m'; OFF=$'\033[0m'

head_() { printf '\n%s>>> %s%s\n' "$BOLD$CYA" "$1" "$OFF"; }
ok()    { printf '  %sOK%s    %s\n' "$GRN" "$OFF" "$1"; }
bad()   { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1"; }
warn()  { printf '  %sWARN%s  %s\n' "$YEL" "$OFF" "$1"; }
info()  { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }

FAIL=0

# ---------------------------------------------------------------------------
# 1. lingkungan
# ---------------------------------------------------------------------------
head_ "1. Lingkungan"

HOST="$(uname -s)"
case "$HOST" in
    Linux)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            ok "host: WSL ($(uname -r))"
        else
            ok "host: Linux ($(uname -r))"
        fi ;;
    Darwin) ok "host: macOS ($(uname -r))" ;;
    *)      warn "host: $HOST — belum diuji, lanjut hati-hati" ;;
esac

PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] && ok "python: $($PY -V 2>&1)" || { bad "python tidak ada"; FAIL=1; }

for c in patch tar; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c: $(command -v "$c")"
    else bad "$c tidak ada"; FAIL=1; fi
done

# CRLF merusak `bash script.sh` dengan pesan '$'\r': command not found'
if grep -rlU $'\r' "$ROOT/xnu"/*.sh "$ROOT"/*.sh "$ROOT/tools"/*.sh 2>/dev/null | head -1 | grep -q .; then
    bad "ada skrip ber-CRLF — jalankan: git config core.autocrlf input && git checkout -- ."
    FAIL=1
else
    ok "skrip ber-LF"
fi

if [ "$FAIL" -ne 0 ]; then
    printf '\n%s>>> Prasyarat dasar belum lengkap, berhenti.%s\n' "$RED" "$OFF"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. toolchain Mach-O — apa yang dibutuhkan XNU
# ---------------------------------------------------------------------------
head_ "2. Toolchain"

# XNU menghasilkan Mach-O, bukan ELF. Jadi clang Linux biasa saja tidak cukup:
# linker-nya harus ld64 (Mach-O), dan build system-nya memanggil `xcrun`.
SDKROOT_DETECT=""
if [ -n "$SDK_ARG" ]; then
    SDKROOT_DETECT="$SDK_ARG"
elif [ -n "${SDKROOT:-}" ]; then
    SDKROOT_DETECT="$SDKROOT"
elif [ -n "${HAKIOS_SDKROOT:-}" ]; then
    SDKROOT_DETECT="$HAKIOS_SDKROOT"
fi

have() { command -v "$1" >/dev/null 2>&1; }

CC_BIN=""; for c in clang clang-18 clang-17 clang-16; do have "$c" && { CC_BIN="$c"; break; }; done
LD64_BIN=""; for c in ld64 arm64-apple-darwin-ld ld64.lld; do have "$c" && { LD64_BIN="$c"; break; }; done
CTF_BIN="";  for c in ctf_insert ctf_insert-ld64; do have "$c" && { CTF_BIN="$c"; break; }; done

TC_MISSING=0

if [ -n "$CC_BIN" ]; then
    ok "clang: $CC_BIN ($($CC_BIN --version 2>/dev/null | head -1))"
else
    bad "clang tidak ada"; TC_MISSING=$((TC_MISSING + 1))
fi

if [ -n "$LD64_BIN" ]; then
    ok "linker Mach-O: $LD64_BIN"
else
    bad "ld64 tidak ada (ld ELF tidak bisa menghasilkan kernel Mach-O)"
    info "  cctools-port menyediakan ld64 untuk Linux"
    TC_MISSING=$((TC_MISSING + 1))
fi

if [ -n "$CTF_BIN" ]; then
    ok "ctf_insert: $CTF_BIN"
else
    bad "ctf_insert tidak ada (bagian dari Apple cctools, dipakai tahap link)"
    TC_MISSING=$((TC_MISSING + 1))
fi

if have kextsymboltool; then
    ok "kextsymboltool: $(command -v kextsymboltool)"
else
    bad "kextsymboltool tidak ada (Apple cctools)"
    TC_MISSING=$((TC_MISSING + 1))
fi

if have unifdef; then
    ok "unifdef: $(command -v unifdef)"
else
    warn "unifdef tidak ada — doconf memakainya untuk menyusun config.*"
    TC_MISSING=$((TC_MISSING + 1))
fi

if [ -n "$SDKROOT_DETECT" ] && [ -d "$SDKROOT_DETECT" ]; then
    if [ -f "$SDKROOT_DETECT/usr/include/Availability.h" ] ||
       [ -f "$SDKROOT_DETECT/System/Library/Frameworks/Foundation.framework/Headers/Foundation.h" ]; then
        ok "SDK: $SDKROOT_DETECT"
    else
        bad "SDKROOT ada tapi bukan SDK Apple yang valid: $SDKROOT_DETECT"
        TC_MISSING=$((TC_MISSING + 1))
    fi
else
    bad "SDKROOT tidak diset (butuh SDK iPhoneOS dari Xcode)"
    info "  contoh: bash tools/wsl-build.sh --sdk ~/sdk/iPhoneOS15.0.sdk"
    TC_MISSING=$((TC_MISSING + 1))
fi

if [ "$TC_MISSING" -eq 0 ]; then
    printf '\n  %sToolchain lengkap.%s\n' "$GRN" "$OFF"
else
    printf '\n  %s%d komponen belum ada.%s\n' "$YEL" "$TC_MISSING" "$OFF"
    cat <<'EOF'

  Kenapa ini tidak bisa diakali:
    XNU menghasilkan kernel Mach-O, dan seluruh build system-nya
    (makedefs/MakeInc.*) memanggil `xcrun`, `ld64`, `ctf_insert`, dan
    `kextsymboltool`. Itu semua biner macOS dari Xcode/cctools, bukan
    paket Linux. Header SDK iPhoneOS juga hanya boleh dipakai kalau kamu
    punya lisensi Xcode.

  Tiga jalan yang benar-benar bisa dipakai:
    a) Jalankan skrip ini di macOS (langsung, tanpa apa pun tambahan).
    b) Pasang macOS di WSL2 lewat KVM (OSX-KVM). Berat: ~40 GB, dan
       installer macOS tetap harus diambil dari Apple.
    c) Jalankan workflow GitHub sekali lagi dari tab Actions (manual).

  Yang TIDAK bisa: meng-compile XNU di WSL/Linux polos dengan clang
  bawaan. Linker-nya ELF, dan tidak ada SDK-nya.
EOF
fi

if [ "$DO_CHECK" -eq 1 ]; then
    printf '\n  (--check: berhenti di sini)\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. source + patch
# ---------------------------------------------------------------------------
head_ "3. Source XNU 8020 + patch 0001..0008"

bash "$ROOT/xnu/apply-8020.sh" || { bad "apply-8020.sh gagal"; exit 1; }

# ---------------------------------------------------------------------------
# 4. ABI: TISSOT harus arm64, bukan arm64e
# ---------------------------------------------------------------------------
head_ "4. ABI (Cortex-A53 tanpa PAC)"

if "$PY" - "$SRC/makedefs/MakeInc.def" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"ifneq\s*\(\$\(filter TISSOT,\$\(CURRENT_MACHINE_CONFIG\)\),\)\s*\n(.*?)\nelse",
              src, re.S)
if not m:
    sys.exit("blok TISSOT arm64/arm64e tidak ditemukan")
if "ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG := arm64" not in m.group(1):
    sys.exit("TISSOT masih arm64e -> PAC, A53 akan fault")
PY
then
    ok "TISSOT -> arm64 (bukan arm64e)"
else
    bad "TISSOT tidak dipetakan ke arm64"; FAIL=1
fi

if grep -qE "MACHINE_FLAGS_ARM64_TISSOT[[:space:]]*=[[:space:]]*-DARM64_BOARD_CONFIG_TISSOT[[:space:]]+-mcpu=cortex-a53" "$SRC/makedefs/MakeInc.def"; then
    ok "-mcpu=cortex-a53"
else
    bad "MACHINE_FLAGS_ARM64_TISSOT bukan -mcpu=cortex-a53"; FAIL=1
fi

# ---------------------------------------------------------------------------
# 5. ADT + DTB + boot image
# ---------------------------------------------------------------------------
head_ "5. ADT + DTB + boot image"

ADT_TEMPLATE="$ROOT/devices/tissot/dt/d22ap_15.6.1.adt"
if [ -f "$ADT_TEMPLATE" ]; then
    if "$PY" "$ROOT/tools/mkadt.py" --template "$ADT_TEMPLATE" --tissot \
         --out "$ROOT/prebuilt/tissot.adt" >/dev/null; then
        ok "mkadt.py -> prebuilt/tissot.adt"
    else
        bad "mkadt.py gagal (jalankan tanpa >/dev/null untuk lihat audit)"; FAIL=1
    fi
else
    warn "template ADT tidak ada — dilewati"
    info "  ambil sendiri: bash devices/tissot/extract-dt.sh"
fi

"$PY" "$ROOT/tools/build_tissot_dtb.py" >/dev/null \
    && ok "build_tissot_dtb.py -> prebuilt/tissot.dtb" \
    || { bad "build_tissot_dtb.py gagal"; FAIL=1; }

# ---------------------------------------------------------------------------
# 6. kompilasi kernel
# ---------------------------------------------------------------------------
head_ "6. Kompilasi kernel"

if [ "$DO_COMPILE" -eq 0 ]; then
    warn "dilewati (--no-compile)"
elif [ "$TC_MISSING" -ne 0 ]; then
    warn "dilewati — toolchain belum lengkap (lihat bagian 2)"
    info "  pipeline lokal tetap lanjut; yang belum bisa hanya kompilasi."
else
    info "menyiapkan shim xcrun untuk host non-macOS..."
    SHIM_DIR="$(mktemp -d)"
    trap 'rm -rf "$SHIM_DIR"' EXIT

    SDK_PLATFORM="$(basename "$(dirname "$(dirname "$SDKROOT_DETECT")")")"
    cat > "$SHIM_DIR/xcrun" <<SHIM
#!/bin/sh
# Shim minimal supaya makefile XNU bisa jalan di luar macOS.
SDK="$SDKROOT_DETECT"
case "\$*" in
  *-show-sdk-path*)        echo "\$SDK" ;;
  *-show-sdk-platform-path*) echo "\$SDK/../../" ;;
  "-find "*|*"-find "*)    t="\${3:-}"; command -v "\$t" || exit 1 ;;
  *) exit 1 ;;
esac
SHIM
    chmod +x "$SHIM_DIR/xcrun"
    export PATH="$SHIM_DIR:$PATH"
    export SDKROOT="$SDKROOT_DETECT"
    info "SDKROOT=$SDKROOT  PLATFORM=$SDK_PLATFORM"

    if [ -x "$BUILD" ]; then
        bash "$BUILD" --force --config DEVELOPMENT --jobs "$(nproc 2>/dev/null || echo 4)" \
            || { bad "kompilasi gagal — baca error pertama di atas"; FAIL=1; }
    else
        bad "xnu-build-arm64.sh tidak ada / tidak executable"; FAIL=1
    fi
fi

# ---------------------------------------------------------------------------
# 7. hasil
# ---------------------------------------------------------------------------
head_ "7. Hasil"

K="$(find "$SRC/BUILD" -type f -name 'kernel.*' 2>/dev/null | head -1)"
if [ -n "$K" ]; then
    ok "kernel: $K ($(wc -c < "$K") byte)"
    "$PY" "$ROOT/tools/make_tissot_bootimg.py" >/dev/null \
        && ok "boot image: prebuilt/tissot-boot.img ($(wc -c < "$ROOT/prebuilt/tissot-boot.img") byte)" \
        || warn "make_tissot_bootimg.py gagal"
else
    warn "kernel.* belum ada — boot image memakai kernel placeholder"
    "$PY" "$ROOT/tools/build_kernel_placeholder_arm64.py" >/dev/null \
        && "$PY" "$ROOT/tools/make_tissot_bootimg.py" >/dev/null \
        && info "prebuilt/tissot-boot.img (placeholder)" \
        || warn "pipeline boot image gagal"
fi

printf '\n%s============================================================%s\n' "$BOLD" "$OFF"
if [ "$FAIL" -ne 0 ]; then
    printf '  %sADA YANG GAGAL%s — lihat baris FAIL di atas.\n' "$RED" "$OFF"
    printf '%s============================================================%s\n' "$BOLD" "$OFF"
    exit 1
elif [ "$TC_MISSING" -ne 0 ]; then
    printf '  Patch + image: %sOK%s\n' "$GRN" "$OFF"
    printf '  Kompilasi    : %sbelum bisa di sini%s (butuh macOS)\n' "$YEL" "$OFF"
    printf '%s============================================================%s\n' "$BOLD" "$OFF"
    exit 3
else
    printf '  %sSemua langkah berhasil.%s\n' "$GRN" "$OFF"
    printf '%s============================================================%s\n' "$BOLD" "$OFF"
    exit 0
fi
