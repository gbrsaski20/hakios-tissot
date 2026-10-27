# ============================================================================
# HakiOS-x86 Makefile
#
# Port of the HakiOS XNU research project to x86_64.
# Like Bliss OS, but for the Darwin/XNU kernel instead of Android/Linux.
#
# Targets:
#   make x86-open     Build the open kernel + placeholder loader + tiny user space
#   make x86-full     Build the full system (needs iOS IPSW)
#   make qemu-open    Run the open kernel in QEMU
#   make qemu         Run the full iOS user space in QEMU
#   make clean        Remove build artifacts
#   make distclean    Remove everything including downloaded sources
# ============================================================================

# Directories
ROOT     := $(CURDIR)
XNU_DIR  := $(ROOT)/xnu
LOADER   := $(ROOT)/xnuloader
USERLAND := $(ROOT)/userland
QEMU_DIR := $(ROOT)/qemu
TOOLS    := $(ROOT)/tools
PREBUILT := $(ROOT)/prebuilt

# Build settings
JOBS     ?= 8
KERNEL_CONFIG ?= DEVELOPMENT

# QEMU settings
QEMU_MEM  ?= 4096
QEMU_CPUS ?= 2
QEMU_DISPLAY ?= gtk
QEMU_SECS ?= 1200

# Kernel command line
KERNEL_CMDLINE ?= "cpus=$(QEMU_CPUS) display=1 input=1 disk=1 net=1 serial=1"

# Programs
QEMU     ?= qemu-system-x86_64
CLANG    ?= clang
MAKE     ?= make

.DEFAULT_GOAL := help

.PHONY: help x86-open x86-full qemu-open qemu clean distclean \
        kernel loader userland images deps tissot tissot-clean \
        xnu8020 xnu8020-check

help:
	@echo "HakiOS-x86 — XNU kernel on x86_64 PC/QEMU"
	@echo ""
	@echo "Build targets:"
	@echo "  make x86-open    Build open kernel + loader + tiny user space"
	@echo "  make x86-full    Build full system (needs IPSW)"
	@echo "  make qemu-open    Run open kernel in QEMU"
	@echo "  make qemu         Run full iOS user space in QEMU"
	@echo "  make clean        Remove build artifacts"
	@echo "  make distclean    Remove everything"
	@echo ""
	@echo "Mi A1 / tissot (ARM64) targets:"
	@echo "  make tissot       Build flashable tissot-boot.img (no compiler needed)"
	@echo "  make tissot-clean Remove tissot artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  JOBS=$(JOBS)          Parallel build jobs"
	@echo "  KERNEL_CONFIG=$(KERNEL_CONFIG)  DEVELOPMENT|RELEASE|DEBUG"
	@echo "  QEMU_MEM=$(QEMU_MEM)         QEMU memory (MB)"
	@echo "  QEMU_CPUS=$(QEMU_CPUS)       QEMU CPU count"
	@echo "  QEMU_DISPLAY=$(QEMU_DISPLAY)  gtk|none|sdl"
	@echo "  QEMU_SECS=$(QEMU_SECS)       Session length (seconds)"

# ============================================================================
# Dependencies: XNU sources + build tools
# ============================================================================

deps:
	@echo ">>> Setting up XNU build dependencies for x86_64..."
	@xnu-deps/setup.sh

# ============================================================================
# Kernel: apply patch + build for X86_64
# ============================================================================

kernel:
	@echo ">>> Building XNU kernel for X86_64..."
	@if [ ! -d "xnu-src" ]; then \
		echo ">>> Applying XNU patch..."; \
		$(XNU_DIR)/apply.sh; \
	fi
	@$(XNU_DIR)/../xnu-build-x86.sh -j$(JOBS) -c $(KERNEL_CONFIG)
	@echo ">>> Kernel built. Copying to prebuilt/..."
	@mkdir -p $(PREBUILT)
	@cp xnu-src/build/obj/$(KERNEL_CONFIG)_X86_64/mach.$(KERNEL_CONFIG).hakios \
		$(PREBUILT)/mach.$(KERNEL_CONFIG).x86_64 2>/dev/null || \
		echo ">>> Note: copy may fail if BUILD dir name differs. Check xnu-src/build/"

# ============================================================================
# Boot loader: UEFI x86_64 application
# ============================================================================

loader:
	@echo ">>> Building xnuloader for x86_64..."
	@$(LOADER)/build.sh
	@mkdir -p $(PREBUILT)
	@cp $(LOADER)/build/xnuloader.efi $(PREBUILT)/ 2>/dev/null || true
	@if [ ! -f "$(PREBUILT)/xnuloader.efi" ]; then \
		echo ">>> Trying Python fallback..."; \
		python3 $(LOADER)/build_efi.py || python $(LOADER)/build_efi.py; \
	fi
	@echo ">>> Loader built."

# ============================================================================
# User space and images
# ============================================================================

userland:
	@echo ">>> Building user space..."
	@REST=1 $(USERLAND)/build.sh

images: userland
	@echo ">>> Images are built as part of userland."

# ============================================================================
# Mi A1 (tissot / MSM8953) — ARM64 Android boot image
#
# Pure Python: no mkbootimg, no dtc, no compiler required.
# Produces a valid Android boot image (header v0, page 2048) containing
# an ARM64 Image + device tree + ramdisk.
# ============================================================================

PYTHON ?= python3

tissot:
	@echo ">>> Building Mi A1 (tissot) ARM64 boot image..."
	@$(PYTHON) tools/build_kernel_placeholder_arm64.py
	@$(PYTHON) tools/build_tissot_dtb.py
	@$(PYTHON) tools/make_tissot_bootimg.py
	@echo ""
	@echo ">>> Done. Flash to Mi A1 (unlocked bootloader):"
	@echo "      fastboot boot prebuilt/tissot-boot.img"

tissot-clean:
	@echo ">>> Removing tissot artifacts..."
	@rm -f prebuilt/tissot-boot.img prebuilt/tissot.dtb prebuilt/tissot.dts \
		prebuilt/tissot-kernel-arm64.Image prebuilt/tissot-ramdisk.cpio.gz
	@echo ">>> Done."

# ============================================================================
# XNU 8020 (iOS 15) — fetch source + apply HakiOS/tissot patches
# Building the kernel itself needs macOS + cctools + SDK (see
# docs/XNU8020-PORT-PLAN.md).
# ============================================================================

xnu8020:
	@./xnu/apply-8020.sh

xnu8020-check:
	@./xnu-build-arm64.sh --check

# ============================================================================
# Open build: kernel + placeholder loader + tiny user space (no IPSW)
# ============================================================================

x86-open: kernel loader
	@echo ">>> Building open user space (no IPSW needed)..."
	@$(USERLAND)/build.sh --open
	@echo ">>> Open build complete."
	@echo ">>> Run with: make qemu-open"

# ============================================================================
# Full build: needs the iOS IPSW
# ============================================================================

x86-full: kernel loader
	@echo ">>> Fetching iOS 16.5 IPSW..."
	@$(ROOT)/sysimage/fetch.sh
	@echo ">>> Building full user space..."
	@REST=1 $(USERLAND)/build.sh
	@echo ">>> Full build complete."
	@echo ">>> Run with: make qemu"

# ============================================================================
# QEMU targets
# ============================================================================

qemu-open:
	@echo ">>> Starting QEMU (open kernel, $(QEMU_SECS)s session)..."
	@mkdir -p logs
	@$(QEMU_DIR)/run-x86.sh $(QEMU_SECS) --open -display $(QEMU_DISPLAY) \
		> logs/qemu-open.log 2>&1

qemu:
	@echo ">>> Starting QEMU (full iOS user space, $(QEMU_SECS)s session)..."
	@mkdir -p logs
	@$(QEMU_DIR)/run-x86.sh $(QEMU_SECS) -display $(QEMU_DISPLAY) \
		> logs/qemu.log 2>&1

# ============================================================================
# Clean
# ============================================================================

clean:
	@echo ">>> Cleaning build artifacts..."
	@rm -rf xnu-src/build xnuloader/build userland/build logs/*.log
	@find . -name "*.o" -delete 2>/dev/null || true

distclean: clean
	@echo ">>> Removing all downloaded/built content..."
	@rm -rf xnu-src xnu-deps/build prebuilt/* userland/*.apfs sysimage/*.ipsw
