@echo off
REM ============================================================================
REM HakiOS / tissot — One-step Mi A1 boot image builder
REM
REM Builds a flashable Android boot image for Xiaomi Mi A1 (tissot) using
REM only Python — no WSL, no clang, no mkbootimg, no dtc needed.
REM
REM Output:
REM   prebuilt\tissot-kernel-arm64.Image   (placeholder ARM64 kernel)
REM   prebuilt\tissot.dtb                  (MSM8953 device tree, FDT)
REM   prebuilt\tissot.adt                  (Apple Device Tree untuk XNU)
REM   prebuilt\tissot-ramdisk.cpio.gz      (minimal ramdisk)
REM   prebuilt\tissot-boot.img             (FLASH THIS)
REM
REM Usage:
REM   make-tissot.bat
REM ============================================================================

setlocal

echo.
echo ================================================
echo   Mi A1 (tissot) Boot Image Builder
echo   (Python-only - no WSL, no compiler needed)
echo ================================================
echo.

REM ---- Find Python ----
echo [1/6] Checking Python...
python --version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo   Python not found in PATH.
    where python 2>nul
    if %ERRORLEVEL% neq 0 (
        echo.
        echo ERROR: Python 3 is required.
        echo   Install from: https://www.python.org/downloads/
        echo   Make sure to check "Add Python to PATH" during install.
        pause
        exit /b 1
    )
)
echo   Python found.
echo.

REM ---- Build ARM64 placeholder kernel ----
echo [2/6] Building ARM64 kernel (tissot-kernel-arm64.Image)...
python "%~dp0tools\build_kernel_placeholder_arm64.py"
if %ERRORLEVEL% neq 0 (
    echo ERROR: ARM64 kernel build failed.
    pause
    exit /b 1
)
echo.

REM ---- Build device tree ----
echo [3/6] Building device tree (tissot.dtb, MSM8953)...
python "%~dp0tools\build_tissot_dtb.py"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Device tree build failed.
    pause
    exit /b 1
)
echo.

REM ---- Build Apple Device Tree (XNU reads this, not the FDT) ----
echo [4/6] Building Apple Device Tree (tissot.adt, MSM8953 overrides)...
python "%~dp0tools\mkadt.py" --template "%~dp0devices\tissot\dt\d22ap_15.6.1.adt" --tissot --out "%~dp0prebuilt\tissot.adt"
if %ERRORLEVEL% neq 0 (
    echo ERROR: ADT build failed. XNU would have no device tree.
    pause
    exit /b 1
)
echo.

REM ---- Pack boot image ----
echo [5/6] Packing Android boot image (tissot-boot.img)...
python "%~dp0tools\make_tissot_bootimg.py"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Boot image packing failed.
    pause
    exit /b 1
)
echo.

REM ---- Done ----
echo [6/6] Done!
echo.
echo ================================================================
echo   Mi A1 boot image created successfully!
echo ================================================================
echo.
echo   Output: %~dp0prebuilt\tissot-boot.img
echo.
echo   NEXT STEPS - flash to your Mi A1
echo.
echo   Prerequisites:
echo     - Mi A1 with UNLOCKED bootloader
echo     - adb + fastboot (Android platform-tools) in PATH
echo     - USB debugging ON, phone connected
echo.
echo   1. Check the device is seen:
echo        fastboot devices
echo.
echo   2. Try WITHOUT flashing (safest - nothing is written):
echo        fastboot boot %~dp0prebuilt\tissot-boot.img
echo.
echo   3. If that works and you want it permanent:
echo        fastboot flash boot %~dp0prebuilt\tissot-boot.img
echo.
echo   4. Restore stock boot if needed (always keep a backup!):
echo        fastboot flash boot stock-boot.img
echo.
echo   IMPORTANT:
echo     The kernel inside is a PLACEHOLDER (wfi spin loop).
echo     A real XNU ARM64 kernel needs cctools + macOS SDK
echo     ^(that is the BUILD machine; the target is still your Mi A1^).
echo     The MSM8953 (ARMv8.0) vs iOS 15 (ARMv8.0-safe) choice is explained
echo     in docs\IOS15-VS-IOS16-ARMv8.md.
echo.
pause

endlocal
