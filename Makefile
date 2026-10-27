# ============================================================================
# HakiOS — XNU (kernel Darwin/iOS) untuk Xiaomi Mi A1 (tissot / MSM8953)
#
# Target: Qualcomm MSM8953, 8x Cortex-A53, ARMv8.0-A, tanpa PAC.
# Sumber kernel: xnu-8020.140.41 (generasi iOS 15), APSL 2.0.
#
# Targets:
#   make tissot         Rakit prebuilt/tissot-boot.img (Python saja, tanpa compiler)
#   make adt            Rakit prebuilt/tissot.adt dari ADT iPhone X + override MSM8953
#   make check          Audit ADT terhadap semua syarat XNU
#   make xnu8020        Unduh source XNU 8020 + terapkan patch 0001..0003
#   make xnu8020-check  Cek toolchain build kernel (butuh macOS)
#   make clean          Hapus artefak build
#   make distclean      Hapus termasuk source yang diunduh
#
# Catatan penting: `make tissot` TIDAK mem-build XNU. Ia merakit boot image
# dari kernel yang sudah ada. Build kernel XNU sendiri butuh macOS + cctools
# + SDK Apple — lihat docs/XNU8020-PORT-PLAN.md bagian 5, atau jalankan
# workflow GitHub Actions ".github/workflows/xnu-tissot.yml".
# ============================================================================

# ---- Directories -----------------------------------------------------------
ROOT     := $(CURDIR)
XNU_DIR  := $(ROOT)/xnu
TOOLS    := $(ROOT)/tools
PREBUILT := $(ROOT)/prebuilt
DEVICE   := $(ROOT)/devices/tissot

# ---- Settings --------------------------------------------------------------
PYTHON   ?= python3
JOBS     ?= 4
KERNEL_CONFIG ?= DEVELOPMENT

# ADT source: the real iPhone X device tree pulled from the iOS 15.6.1 IPSW.
# Required by MobileGestalt, so the iPhone X identity is kept on purpose.
ADT_TEMPLATE ?= $(DEVICE)/dt/d22ap_15.6.1.adt

.DEFAULT_GOAL := help

.PHONY: help tissot adt check xnu8020 xnu8020-check kernel-clean \
        clean distclean

# ============================================================================
help:
	@echo "HakiOS — XNU untuk Xiaomi Mi A1 (tissot / MSM8953, ARM64)"
	@echo ""
	@echo "Rakit (tidak butuh compiler):"
	@echo "  make adt            Rakit prebuilt/tissot.adt (ADT untuk XNU)"
	@echo "  make check          Audit ADT terhadap syarat XNU (12 cek)"
	@echo "  make tissot         Rakit prebuilt/tissot-boot.img"
	@echo ""
	@echo "Kernel XNU (butuh macOS / GitHub Actions):"
	@echo "  make xnu8020        Unduh source + terapkan patch 0001..0003"
	@echo "  make xnu8020-check  Cek toolchain (akan gagal di Windows/Linux)"
	@echo ""
	@echo "Bersih-bersih:"
	@echo "  make clean          Hapus artefak build"
	@echo "  make distclean      Hapus termasuk source yang diunduh"
	@echo ""
	@echo "Variabel:"
	@echo "  PYTHON=$(PYTHON)   JOBS=$(JOBS)   KERNEL_CONFIG=$(KERNEL_CONFIG)"
	@echo ""
	@echo "Alur lengkap: make adt -> (build kernel di CI) -> make tissot"
	@echo "             -> fastboot boot prebuilt/tissot-boot.img"

# ============================================================================
# ADT — Apple Device Tree untuk MSM8953
#
# XNU TIDAK memakai FDT Linux. Ia memakai format Device Tree milik Apple,
# dibaca lewat SecureDT*. mkadt.py mengambil ADT asli iPhone X lalu
# menimpa bagian yang dibutuhkan MSM8953:
#   /arm-io:ranges            -> soc base 0x07800000
#   /arm-io/serial:reg        -> UART 0x78AF000
#   /arm-io/aic -> /arm-io/gic-> GIC-400 (GICv2) 0x0B000000 / 0x0B002000
#   /arm-io/gic-timebase      -> node device_type=timer
#   /cpus/cpuN:*frequency*    -> 19.2 MHz dsb (ADT asli semua 0 -> bagi nol)
#   /memory:reg               -> 0x80000000 + 4 GiB
# ============================================================================

adt:
	@echo ">>> Merakit ADT untuk tissot..."
	@$(PYTHON) $(TOOLS)/mkadt.py --template "$(ADT_TEMPLATE)" --tissot \
		--out $(PREBUILT)/tissot.adt

check:
	@echo ">>> Audit ADT terhadap syarat XNU (mkadt.py gagal kalau ada yang kurang)..."
	@$(PYTHON) $(TOOLS)/mkadt.py --template "$(ADT_TEMPLATE)" --tissot \
		--out $(PREBUILT)/tissot.adt | sed -n '/requirement audit/,/^$$/p'

# ============================================================================
# Boot image Android untuk tissot
#
# Format: Android boot image header v0, page 2048.
#   page 0      header + padding
#   page 1..N   kernel  (Image.gz + DTB appended = "Image.gz-dtb")
#   page N+1..  ramdisk (cpio.gz minimal)
#   setelahnya  ADT Apple (ekstensi kita; alamat fisiknya dicetak untuk SHIM)
#
# mkbootimg, dtc, dan compiler semuanya TIDAK dibutuhkan.
# ============================================================================

tissot:
	@echo ">>> Merakit boot image Mi A1 (tissot)..."
	@if [ ! -f "$(PREBUILT)/tissot-kernel-arm64.Image" ]; then \
		echo ">>> Kernel belum ada — memakai placeholder (wfi spin loop)."; \
		$(PYTHON) $(TOOLS)/build_kernel_placeholder_arm64.py; \
	fi
	@if [ ! -f "$(PREBUILT)/tissot.dtb" ]; then \
		echo ">>> DTB belum ada — membuat dari template tissot."; \
		$(PYTHON) $(TOOLS)/build_tissot_dtb.py; \
	fi
	@if [ ! -f "$(PREBUILT)/tissot.adt" ]; then \
		echo ">>> ADT belum ada — merakit dulu."; \
		$(MAKE) --no-print-directory adt; \
	fi
	@$(PYTHON) $(TOOLS)/make_tissot_bootimg.py
	@echo ""
	@echo ">>> Selesai. Flash ke Mi A1 (bootloader harus unlocked):"
	@echo "      fastboot devices"
	@echo "      fastboot boot  prebuilt/tissot-boot.img    # coba tanpa menulis"
	@echo "      fastboot flash boot prebuilt/tissot-boot.img"

# ============================================================================
# Kernel XNU 8020 (iOS 15)
# ============================================================================

xnu8020:
	@echo ">>> Menyiapkan source XNU 8020 + patch tissot..."
	@./xnu/apply-8020.sh

xnu8020-check:
	@./xnu-build-arm64.sh --check

# ============================================================================
# Clean
# ============================================================================

clean:
	@echo ">>> Menghapus artefak build..."
	@rm -f prebuilt/tissot-boot.img prebuilt/tissot.dtb prebuilt/tissot.dts \
		prebuilt/tissot-kernel-arm64.Image prebuilt/tissot-ramdisk.cpio.gz \
		prebuilt/tissot.adt
	@rm -f logs/*.log
	@echo ">>> Selesai. (prebuilt/tissot-kernel-arm64.Image hasil CI juga dihapus)"

distclean: clean
	@echo ">>> Menghapus termasuk source yang diunduh..."
	@rm -rf xnu-src-8020 xnu-deps/build xnu-src
	@echo ">>> Selesai."
