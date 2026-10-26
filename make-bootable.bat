@echo off
REM ============================================================================
REM HakiOS-x86 — One-step Bootable USB Image Builder
REM
REM This is the easiest way to create a bootable USB image for HakiOS-x86.
REM It builds everything using Python (no WSL, no clang, no external tools).
REM
REM Just run this script, then flash the resulting .img with Rufus.
REM
REM Usage:
REM   make-bootable.bat           Build everything + create Rufus image
REM ============================================================================

setlocal

echo.
echo ================================================
echo   HakiOS-x86 Bootable Image Builder
echo   (Python-only — no WSL needed!)
echo ================================================
echo.

REM ---- Find Python ----
echo [1/5] Checking Python...
python --version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo   Python not found in PATH.
    echo   Trying common locations...
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

REM ---- Build xnuloader.efi ----
echo [2/5] Building UEFI boot loader (xnuloader.efi)...
python "%~dp0xnuloader\build_efi.py"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Boot loader build failed.
    pause
    exit /b 1
)
echo.

REM ---- Build placeholder kernel ----
echo [3/5] Building kernel (mach_kernel placeholder)...
python "%~dp0tools\build_kernel_placeholder.py"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Kernel build failed.
    pause
    exit /b 1
)
echo.

REM ---- Create Rufus image ----
echo [4/5] Creating Rufus-flashable image (hakios-x86.img)...
python "%~dp0tools\make_rufus_img.py"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Image creation failed.
    pause
    exit /b 1
)
echo.

REM ---- Done ----
echo [5/5] Done!
echo.
echo ================================================================
echo   Bootable image created successfully!
echo ================================================================
echo.
echo   Output: %~dp0prebuilt\hakios-x86.img  (256 MB)
echo.
echo   NEXT STEPS — Flash to USB with Rufus:
echo.
echo   1. Download Rufus from https://rufus.ie
echo   2. Insert a USB drive (8GB+ recommended)
echo   3. Open Rufus
echo   4. Click SELECT and choose:
echo      %~dp0prebuilt\hakios-x86.img
echo   5. Set Partition scheme: GPT
echo   6. Set Target system: UEFI (non-CSM)
echo   7. Click START
echo   8. If Rufus asks, choose "DD Image" mode (NOT ISO mode)
echo   9. When done, boot your PC from the USB drive
echo      (enable UEFI boot in your BIOS if needed)
echo.
echo   ALTERNATIVELY — Flash with dd (Git Bash):
echo   dd if=prebuilt\hakios-x86.img of=/dev/sdX bs=4M conv=fsync
echo.
echo   NOTE: This image contains a placeholder kernel.
echo   For the real XNU kernel, install WSL and run:
echo   build-windows.bat rufus
echo.
pause

endlocal
