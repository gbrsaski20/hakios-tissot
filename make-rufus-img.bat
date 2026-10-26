@echo off
REM ============================================================================
REM HakiOS-x86 Rufus Image Builder for Windows
REM
REM Creates a Rufus-flashable .img file that you can write to a USB drive.
REM
REM This script tries WSL2 first (full build), then falls back to Python
REM (builds xnuloader.efi + placeholder kernel + FAT32 image natively).
REM
REM Usage:
REM   make-rufus-img.bat                 Build image (default output)
REM   make-rufus-img.bat full            Build full system first, then image
REM   make-rufus-img.bat clean           Clean + build + image
REM   make-rufus-img.bat nopython        Force Python-only path (skip WSL)
REM
REM After the .img is created, open Rufus, select the .img file,
REM choose "DD Image" mode, and write to USB.
REM ============================================================================

setlocal
set MODE=open
set CLEAN=
set NO_WSL=0

:parse
if "%1"=="" goto run
if /i "%1"=="full" set MODE=full
if /i "%1"=="open" set MODE=open
if /i "%1"=="clean" set CLEAN=-Clean
if /i "%1"=="-clean" set CLEAN=-Clean
if /i "%1"=="nopython" set NO_WSL=1
if /i "%1"=="python" set NO_WSL=1
shift
goto parse

:run
echo ============================================
echo   HakiOS-x86 Rufus Image Builder
echo   Mode: %MODE%  Clean: %CLEAN%  NoWSL: %NO_WSL%
echo ============================================
echo.

REM ============================================================================
REM Path 1: Python-only build (no WSL needed)
REM ============================================================================
REM Build xnuloader.efi, placeholder kernel, and Rufus image entirely in Python.
REM This works on any Windows with Python installed — no WSL, no clang, no mtools.
REM ============================================================================

echo [1/4] Building xnuloader.efi (Python)...
python "%~dp0xnuloader\build_efi.py"
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: xnuloader.efi build failed.
    echo Make sure Python 3 is installed and in PATH.
    pause
    exit /b 1
)

echo.
echo [2/4] Building placeholder kernel (Python)...
python "%~dp0tools\build_kernel_placeholder.py"
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Kernel placeholder build failed.
    pause
    exit /b 1
)

echo.
echo [3/4] Creating Rufus image (Python)...
python "%~dp0tools\make_rufus_img.py"
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: Rufus image creation failed.
    pause
    exit /b 1
)

echo.
echo [4/4] Done!
echo.
echo ============================================
echo   Rufus image created successfully!
echo ============================================
echo.
echo   Output: %~dp0prebuilt\hakios-x86.img
echo.
echo   To flash with Rufus:
echo     1. Download Rufus from https://rufus.ie
echo     2. Open Rufus, click SELECT, choose:
echo        %~dp0prebuilt\hakios-x86.img
echo     3. Partition scheme: GPT
echo     4. Target system: UEFI (non-CSM)
echo     5. Click START
echo     6. Choose 'DD Image' mode if asked
echo     7. Boot from USB (enable UEFI in BIOS)
echo.
echo   NOTE: This image uses a placeholder kernel.
echo   For the real XNU kernel, build with WSL:
echo     build-windows.bat rufus
echo.
pause

endlocal
