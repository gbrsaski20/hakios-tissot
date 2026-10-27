#!/usr/bin/env bash
# ============================================================================
# tools/wsl-check.sh — jalankan pemeriksaan HakiOS/tissot di dalam WSL/Linux
#
# Tujuan: mereproduksi job "patches" dari GitHub Actions secara lokal, supaya
# iterasi patch tidak perlu menunggu runner macOS 5-6 menit setiap kali.
#
# Yang DIPERIKSA di sini:
#   1. tool yang dibutuhkan (python3, patch, git, tar, curl/wget)
#   2. patch 0001..0008 apply bersih ke source XNU pristine
#   3. penanda tiap patch benar-benar ada (sama seperti job patches)
#   4. TISSOT dipetakan ke arm64, bukan arm64e (Cortex-A53 tanpa PAC)
#   5. -mcpu=cortex-a53 ada di MACHINE_FLAGS_ARM64_TISSOT
#   6. ADT + DTB + kernel placeholder + boot image bisa dirakit
#
# Yang TIDAK BISA dilakukan di sini: mengompilasi kernel XNU. Itu butuh
# clang + cctools (ld Mach-O, ctf_insert, kextsymboltool) + SDK Apple, dan
# hanya jalan di macOS. Script ini melaporkan kondisi itu, bukan berpura-pura
# bisa. Build kernel tetap lewat GitHub Actions (runner macOS).
#
# Pakai (dari dalam Ubuntu/WSL):
#   bash /mnt/e/workbuddyainew/2026-10-26-09-55-05/tools/wsl-check.sh
#   bash tools/wsl-check.sh --no-fetch     # kalau source XNU sudah ada
# ============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FETCH=1
[ "${1:-}" = "--no-fetch" ] && FETCH=0

PASS=0
FAIL=0
SKIP=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIP=$((SKIP + 1)); }
head_() { printf '\n\033[1m>>> %s\033[0m\n' "$1"; }

printf '============================================================\n'
printf '  HakiOS / tissot — pemeriksaan lokal (WSL / Linux)\n'
printf '============================================================\n'
printf '  root : %s\n' "$ROOT"
printf '  host : %s\n' "$(uname -srm 2>/dev/null || echo '?')"
printf '\n'

# ---------------------------------------------------------------------------
# 1. environment
# ---------------------------------------------------------------------------
head_ "1. Lingkungan"

need() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 : $(command -v "$1")"
    else
        bad "$1 tidak ada — install: $2"
    fi
}
need python3 "apt install python3"
need patch   "apt install patch"
need git     "apt install git"
need tar     "apt install tar"

if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    ok "curl/wget ada (untuk unduh source XNU)"
else
    bad "curl dan wget tidak ada — apt install curl"
fi

# CRLF akan membuat 'bash script.sh' gagal dengan $'\r': command not found.
# Repo ini punya .gitattributes yang memaksa LF, tapi working tree Windows
# bisa saja masih CRLF kalau di-checkout dengan core.autocrlf=true.
if grep -q $'\r' "$ROOT/xnu/apply-8020.sh" 2>/dev/null; then
    bad "xnu/apply-8020.sh ber-CRLF (bash akan gagal)"
    printf '        perbaiki: git -C "%s" config core.autocrlf input\n' "$ROOT"
    printf '                  git -C "%s" rm --cached -r . >/dev/null; git -C "%s" reset --hard\n' "$ROOT" "$ROOT"
else
    ok "skrip ber-LF (tidak ada CRLF)"
fi

if [ "$FAIL" -ne 0 ]; then
    printf '\n\033[31m>>> Ada tool yang kurang. Perbaiki dulu, lalu jalankan lagi.\033[0m\n'
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. source XNU + patch
# ---------------------------------------------------------------------------
head_ "2. Source XNU + patch series"

if [ "$FETCH" -eq 1 ]; then
    if bash "$ROOT/xnu/apply-8020.sh"; then
        ok "apply-8020.sh selesai"
    else
        bad "apply-8020.sh gagal"
    fi
else
    skip "apply-8020.sh (--no-fetch)"
fi

SRC="$ROOT/xnu-src-8020"

# ---------------------------------------------------------------------------
# 3. penanda tiap patch — daftar ini harus sama dengan job 'patches' di CI
# ---------------------------------------------------------------------------
head_ "3. Penanda patch"

chk() {
    if [ ! -f "$SRC/$1" ]; then
        bad "$1 tidak ada"
        return
    fi
    if grep -q "$2" "$SRC/$1"; then
        ok "$1 :: $2"
    else
        bad "$1 :: $2 TIDAK ADA"
    fi
}
chk_absent() {
    if grep -q "$2" "$SRC/$1" 2>/dev/null; then
        bad "$1 :: masih ada $2"
    else
        ok "$1 :: tanpa $2"
    fi
}

chk pexpert/pexpert/arm64/TISSOT.h          "TISSOT_GIC_V2"
chk makedefs/MakeInc.def                    "MACHINE_FLAGS_ARM64_TISSOT"
chk pexpert/pexpert/arm64/board_config.h    "ARM64_BOARD_CONFIG_TISSOT"
chk pexpert/pexpert/arm/protos.h            "SERIAL_TISSOT_UART"
chk pexpert/arm/pe_serial.c                 "tissot_uart_init"
chk pexpert/arm/pe_fiq.c                    "tissot_gic_init_distributor"
chk pexpert/arm/pe_fiq.c                    "pe_gic_ack_irq"
chk osfmk/arm64/sleh.c                      "pe_gic_ack_irq"
chk bsd/sys/make_symbol_aliasing.sh         "HAKIOS_HOST_SDK"
chk bsd/sys/make_symbol_aliasing.sh         "HAKIOS_STATIC_LIST"
chk makedefs/MakeInc.def                    "Wno-missing-include-dirs"
chk makedefs/MakeInc.def                    "Not every SDK ships usr/local/include/kernel"
chk_absent makedefs/MakeInc.def             "enable-trivial-auto-var-init-zero"
chk makedefs/MakeInc.def                    "Wno-reserved-identifier"
chk pexpert/pexpert/arm64/Makefile          "TISSOT.h"
chk osfmk/arm/proc_reg.h                    "ARM64_BOARD_CONFIG_TISSOT"
chk iokit/Kernel/IOStartIOKit.cpp           "!defined(ARM64_BOARD_CONFIG_TISSOT)"

# ---------------------------------------------------------------------------
# 4. TISSOT harus arm64, bukan arm64e
# ---------------------------------------------------------------------------
head_ "4. Target ABI (Cortex-A53 tanpa PAC)"

if python3 - "$SRC/makedefs/MakeInc.def" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"ifneq\s*\(\$\(filter TISSOT,\$\(CURRENT_MACHINE_CONFIG\)\),\)\s*\n(.*?)\nelse", src, re.S)
if not m:
    sys.exit("blok TISSOT arm64/arm64e tidak ditemukan")
if "ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG := arm64" not in m.group(1):
    sys.exit("TISSOT masih arm64e -> PAC, A53 akan fault")
PY
then
    ok "TISSOT -> arm64 (bukan arm64e)"
else
    bad "TISSOT tidak dipetakan ke arm64"
fi

if grep -qE "MACHINE_FLAGS_ARM64_TISSOT[[:space:]]*=[[:space:]]*-DARM64_BOARD_CONFIG_TISSOT[[:space:]]+-mcpu=cortex-a53" "$SRC/makedefs/MakeInc.def"; then
    ok "-mcpu=cortex-a53"
else
    bad "MACHINE_FLAGS_ARM64_TISSOT bukan -mcpu=cortex-a53"
fi

# ---------------------------------------------------------------------------
# 5. pipeline image (murni Python)
# ---------------------------------------------------------------------------
head_ "5. ADT + DTB + boot image"

ADT_TEMPLATE="$ROOT/devices/tissot/dt/d22ap_15.6.1.adt"
if [ -f "$ADT_TEMPLATE" ]; then
    if python3 "$ROOT/tools/mkadt.py" --template "$ADT_TEMPLATE" --tissot \
         --out "$ROOT/prebuilt/tissot.adt" >/dev/null 2>&1; then
        ok "mkadt.py (audit 12 syarat XNU lolos)"
    else
        bad "mkadt.py gagal (jalankan tanpa >/dev/null untuk lihat audit)"
    fi
else
    skip "mkadt.py — $ADT_TEMPLATE tidak ada (data Apple, tidak di-commit)"
    printf '        ambil sendiri: bash devices/tissot/extract-dt.sh\n'
fi

python3 "$ROOT/tools/build_tissot_dtb.py" >/dev/null 2>&1 \
    && ok "build_tissot_dtb.py" || bad "build_tissot_dtb.py gagal"
python3 "$ROOT/tools/build_kernel_placeholder_arm64.py" >/dev/null 2>&1 \
    && ok "build_kernel_placeholder_arm64.py" || bad "placeholder gagal"

if python3 "$ROOT/tools/make_tissot_bootimg.py" >/dev/null 2>&1; then
    ok "make_tissot_bootimg.py -> prebuilt/tissot-boot.img ($(wc -c < "$ROOT/prebuilt/tissot-boot.img") byte)"
else
    bad "make_tissot_bootimg.py gagal"
fi

# ---------------------------------------------------------------------------
# 6. kenapa kompilasi tidak bisa di sini
# ---------------------------------------------------------------------------
head_ "6. Kompilasi kernel (informatif)"

printf '  clang     : %s\n' "$(command -v clang || echo 'tidak ada')"
printf '  ld        : %s\n' "$(command -v ld || echo 'tidak ada')"
printf '  ctf_insert: %s\n' "$(command -v ctf_insert || echo 'tidak ada (bagian cctools Apple)')"
printf '  host      : %s\n' "$(uname -s)"
printf '\n  XNU butuh clang + cctools + SDK Apple, dan build system-nya\n'
printf '  berasumsi macOS. Jadi kompilasi TIDAK mungkin di WSL/Linux.\n'
printf '  Build kernel tetap lewat GitHub Actions (runner macOS):\n'
printf '    tab Actions -> xnu-tissot -> Run workflow\n'
printf '  Script ini memastikan semua yang BISA dicek di Linux memang benar,\n'
printf '  supaya kegagalan di CI bukan soal patch lagi.\n'

# ---------------------------------------------------------------------------
# ringkasan
# ---------------------------------------------------------------------------
printf '\n============================================================\n'
printf '  OK: %d   FAIL: %d   SKIP: %d\n' "$PASS" "$FAIL" "$SKIP"
printf '============================================================\n'

if [ "$FAIL" -ne 0 ]; then
    printf '\033[31m>>> Ada %d masalah. Lihat baris FAIL di atas.\033[0m\n' "$FAIL"
    exit 1
fi
printf '\033[32m>>> Semua pemeriksaan lokal lolos.\033[0m\n'
printf '    Berikutnya: jalankan workflow CI untuk build kernel sungguhan.\n'
