#!/bin/bash
# ============================================================================
# tools/macos-vm-preflight.sh — cek apakah WSL ini bisa menjalankan macOS di
# QEMU/KVM. Jalankan DI DALAM WSL, bukan di Windows.
#
#   bash tools/macos-vm-preflight.sh
#   bash tools/macos-vm-preflight.sh --dir /mnt/e/macos-vm
#
# Kode keluar:
#   0  siap (semua syarat keras terpenuhi)
#   1  ada syarat keras yang belum terpenuhi — lihat baris FAIL
#   2  jalan, tapi ada peringatan (RAM/disk ketat)
# ============================================================================
set -u

VM_DIR="/mnt/e/macos-vm"
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) VM_DIR="${2:-}"; shift ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "argumen tidak dikenal: $1" >&2; exit 1 ;;
    esac
    shift
done

B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'
Y=$'\033[33m'; C=$'\033[36m'; O=$'\033[0m'

h()  { printf '\n%s>>> %s%s\n' "$B$C" "$1" "$O"; }
ok() { printf '  %sOK%s    %s\n' "$G" "$O" "$1"; }
no() { printf '  %sFAIL%s  %s\n' "$R" "$O" "$1"; }
wr() { printf '  %sWARN%s  %s\n' "$Y" "$O" "$1"; }
inf(){ printf '  %s%s%s\n' "$D" "$1" "$O"; }

HARD=0
SOFT=0

printf '%s============================================================%s\n' "$B" "$O"
printf '%s  Preflight: macOS di WSL2 lewat QEMU/KVM%s\n' "$B" "$O"
printf '%s============================================================%s\n' "$B" "$O"

# ---------------------------------------------------------------------------
h "1. WSL dan Windows"
# ---------------------------------------------------------------------------
if grep -qi microsoft /proc/version 2>/dev/null; then
    ok "berjalan di WSL ($(uname -r))"
else
    wr "bukan WSL — lewati bagian khusus WSL, sisanya tetap relevan"
fi

if [ -r /proc/sys/kernel/osrelease ]; then
    inf "kernel: $(cat /proc/sys/kernel/osrelease)"
fi

# ---------------------------------------------------------------------------
h "2. Virtualisasi CPU (syarat keras)"
# ---------------------------------------------------------------------------
# WSL2 sendiri sudah berjalan di atas hypervisor. Supaya QEMU di dalamnya bisa
# memakai KVM, hypervisor Windows harus meneruskan ekstensi virtualisasi
# (SVM untuk AMD, VMX untuk Intel) ke guest WSL.
CPUFLAGS="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2)"
if [ -z "$CPUFLAGS" ]; then
    no "tidak bisa membaca /proc/cpuinfo"; HARD=1
elif echo "$CPUFLAGS" | grep -qw svm; then
    ok "CPU AMD, SVM diteruskan ke WSL"
elif echo "$CPUFLAGS" | grep -qw vmx; then
    ok "CPU Intel, VMX diteruskan ke WSL"
else
    no "SVM/VMX tidak terlihat di /proc/cpuinfo"
    inf "  artinya nested virtualization belum aktif."
    inf "  Perbaikan ada di Windows, bukan di WSL:"
    inf "    C:\\Users\\<nama>\\.wslconfig  ->  [wsl2]  nestedVirtualization=true"
    inf "    lalu: wsl --shutdown"
    HARD=1
fi

# ---------------------------------------------------------------------------
h "3. /dev/kvm (syarat keras)"
# ---------------------------------------------------------------------------
# Inilah gerbang sebenarnya. Tanpa /dev/kvm, QEMU jatuh ke emulasi TCG murni:
# macOS akan butuh puluhan menit hanya untuk boot, dan build Xcode tidak
# realistis. Jangan lanjut kalau baris ini FAIL.
if [ -c /dev/kvm ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ok "/dev/kvm ada dan bisa dipakai"
    else
        no "/dev/kvm ada tapi tidak bisa diakses user ini"
        inf "  sudo usermod -aG kvm \$USER   (lalu logout/login WSL)"
        HARD=1
    fi
else
    no "/dev/kvm tidak ada"
    HARD=1
fi

if lsmod 2>/dev/null | grep -q '^kvm'; then
    ok "modul kvm termuat: $(lsmod | awk '/^kvm/{print $1}' | tr '\n' ' ')"
else
    inf "modul kvm tidak terlihat di lsmod"
    if command -v modprobe >/dev/null 2>&1; then
        inf "  coba: sudo modprobe kvm_amd   (AMD)  /  sudo modprobe kvm_intel (Intel)"
    fi
fi

# ---------------------------------------------------------------------------
h "4. RAM dan CPU"
# ---------------------------------------------------------------------------
MEM_MB="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
NPROC="$(nproc 2>/dev/null || echo 0)"
inf "RAM terlihat WSL : ${MEM_MB:-?} MB"
inf "core tersedia    : $NPROC"

if [ -n "${MEM_MB:-}" ] && [ "$MEM_MB" -ge 10000 ]; then
    ok "RAM cukup untuk VM macOS 8 GB"
elif [ -n "${MEM_MB:-}" ] && [ "$MEM_MB" -ge 7000 ]; then
    wr "RAM ketat — VM 8 GB akan membuat Windows swap"
    inf "  naikkan di .wslconfig: memory=10GB, lalu wsl --shutdown"
    SOFT=1
else
    wr "RAM WSL < 7 GB — VM macOS akan sangat lambat"
    inf "  .wslconfig: [wsl2] memory=10GB"
    SOFT=1
fi

if [ "$NPROC" -ge 4 ]; then
    ok "$NPROC core — cukup untuk build XNU"
else
    wr "core < 4 — build XNU akan lama"
    SOFT=1
fi

# ---------------------------------------------------------------------------
h "5. Disk"
# ---------------------------------------------------------------------------
inf "target VM: $VM_DIR"
PARENT="$VM_DIR"
while [ ! -d "$PARENT" ] && [ "$PARENT" != "/" ]; do PARENT="$(dirname "$PARENT")"; done
FREE_GB="$(df -BG --output=avail "$PARENT" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "${FREE_GB:-}" ] && [ "$FREE_GB" -ge 80 ]; then
    ok "$PARENT: ${FREE_GB} GB bebas"
elif [ -n "${FREE_GB:-}" ] && [ "$FREE_GB" -ge 50 ]; then
    wr "$PARENT: ${FREE_GB} GB bebas — pas-pasan (macOS + Xcode ~50-60 GB)"
    SOFT=1
else
    no "$PARENT: ${FREE_GB:-?} GB bebas — butuh minimal 50 GB, nyaman 80 GB"
    HARD=1
fi
inf "qcow2 dibuat sparse, jadi baru terpakai seiring instalasi."

# ---------------------------------------------------------------------------
h "6. Paket yang dibutuhkan"
# ---------------------------------------------------------------------------
need_pkg() {
    if command -v "$1" >/dev/null 2>&1; then ok "$1"
    else wr "$1 belum ada"; inf "  sudo apt install $2"; SOFT=1; fi
}
need_pkg qemu-system-x86_64 "qemu-system-x86 qemu-utils"
need_pkg qemu-img            "qemu-utils"
need_pkg dmg2img             "dmg2img"
need_pkg wget                "wget"
need_pkg git                 "git"

if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    inf "versi: $(qemu-system-x86_64 --version | head -1)"
fi

# ---------------------------------------------------------------------------
h "Kesimpulan"
# ---------------------------------------------------------------------------
if [ "$HARD" -ne 0 ]; then
    cat <<'EOF'

  BELUM BISA. Syarat keras di atas belum terpenuhi.

  Yang paling sering: /dev/kvm tidak ada. Itu bukan salah setelan WSL —
  kernel WSL bawaan Microsoft belum tentu menyertakan modul KVM. Dua jalan:

    a) Bangun kernel WSL sendiri dengan KVM aktif. Lihat
       docs/MACOS-VM-WSL.md bagian "Kalau /dev/kvm tidak ada".
    b) Pakai QEMU untuk Windows + WHPX, tanpa WSL sama sekali.
       Akselerasinya dari Hyper-V, yang di mesin ini sudah aktif.

  Jangan memaksa lanjut dengan emulasi TCG: macOS bisa butuh >30 menit
  hanya untuk sampai installer, dan build Xcode praktis tidak selesai.
EOF
    printf '\n%s============================================================%s\n' "$B" "$O"
    exit 1
fi

if [ "$SOFT" -ne 0 ]; then
    printf '\n  %sBisa jalan, tapi ada peringatan di atas.%s\n' "$Y" "$O"
    printf '%s============================================================%s\n' "$B" "$O"
    exit 2
fi

cat <<EOF

  SIAP. Langkah berikutnya:

    mkdir -p $VM_DIR
    cd $VM_DIR
    git clone --depth 1 --recursive https://github.com/kholia/OSX-KVM.git
    cd OSX-KVM
    ./fetch-macOS-v2.py          # unduh BaseSystem dari server Apple
    dmg2img -i BaseSystem.dmg BaseSystem.img
    qemu-img create -f qcow2 mac_hdd_ng.img 128G
    ./OpenCore-Boot.sh           # boot installer

  Panduan lengkap: docs/MACOS-VM-WSL.md
EOF
printf '%s============================================================%s\n' "$B" "$O"
exit 0
