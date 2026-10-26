@echo off
REM ============================================================================
REM HakiOS-x86 Build Launcher for Windows
REM
REM This script tries WSL2 first (full XNU build), then falls back to Python
REM (builds xnuloader.efi + placeholder kernel natively on Windows).
REM
REM Usage:
REM   build-windows.bat            Build open mode (WSL) or Python fallback
REM   build-windows.bat full       Build full mode (downloads iOS IPSW, needs WSL)
REM   build-windows.bat clean      Clean + build open mode
REM   build-windows.bat rufus      Build + create Rufus-flashable .img
REM   build-windows.bat clean rufus  Clean + build + Rufus image
REM   build-windows.bat python     Python-only build (no WSL, placeholder kernel)
REM ============================================================================

setlocal
set MODE=open
set CLEAN=
set RUFUS=
set PYTHON_ONLY=0

:parse
if "%1"=="" goto run
if /i "%1"=="full" set MODE=full
if /i "%1"=="open" set MODE=open
if /i "%1"=="clean" set CLEAN=-Clean
if /i "%1"=="-clean" set CLEAN=-Clean
if /i "%1"=="rufus" set RUFUS=-Rufus
if /i "%1"=="-rufus" set RUFUS=-Rufus
if /i "%1"=="python" set PYTHON_ONLY=1
shift
goto parse

:run
echo HakiOS-x86 Build for Windows
echo Mode: %MODE%  Clean: %CLEAN%  Rufus: %RUFUS%  PythonOnly: %PYTHON_ONLY%
echo.

REM ============================================================================
REM Python-only path: build xnuloader.efi + placeholder kernel + Rufus image
REM ============================================================================
if "%PYTHON_ONLY%"=="1" (
    echo ============================================
    echo   Python-only build (no WSL needed)
    echo ============================================
    echo.

    echo [1/3] Building xnuloader.efi...
    python "%~dp0xnuloader\build_efi.py"
    if %ERRORLEVEL% neq 0 (
        echo ERROR: xnuloader.efi build failed.
        pause
        exit /b 1
    )

    echo.
    echo [2/3] Building placeholder kernel...
    python "%~dp0tools\build_kernel_placeholder.py"
    if %ERRORLEVEL% neq 0 (
        echo ERROR: Kernel build failed.
        pause
        exit /b 1
    )

    echo.
    echo [3/3] Building Rufus image...
    python "%~dp0tools\make_rufus_img.py"
    if %ERRORLEVEL% neq 0 (
        echo ERROR: Rufus image build failed.
        pause
        exit /b 1
    )

    echo.
    echo ============================================
    echo   Python build complete!
    echo ============================================
    echo.
    echo   Binaries in prebuilt\:
    echo     xnuloader.efi              (UEFI boot loader)
    echo     mach.development.x86_64    (placeholder kernel)
    echo     hakios-x86.img             (Rufus-flashable image)
    echo.
    echo   Flash with Rufus:
    echo     1. Open Rufus (https://rufus.ie)
    echo     2. SELECT: prebuilt\hakios-x86.img
    echo     3. Partition: GPT, Target: UEFI (non-CSM)
    echo     4. START (choose DD Image mode)
    echo     5. Boot from USB
    echo.
    echo   For real XNU kernel, use WSL: build-windows.bat
    echo.
    pause
    exit /b 0
)

REM ============================================================================
REM WSL path: full XNU kernel build
REM ============================================================================
powershell -ExecutionPolicy Bypass -File "%~dp0build-windows.ps1" -Mode %MODE% %CLEAN% %RUFUS%

if %ERRORLEVEL% neq 0 (
    echo.
    echo WSL build failed. Falling back to Python-only build...
    echo.
    python "%~dp0xnuloader\build_efi.py" && ^
    python "%~dp0tools\build_kernel_placeholder.py" && ^
    python "%~dp0tools\make_rufus_img.py"
)

endlocal
