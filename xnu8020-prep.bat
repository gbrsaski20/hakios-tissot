@echo off
REM ============================================================================
REM HakiOS / tissot - siapkan source XNU 8020 (iOS 15) + patch
REM
REM Ini HANYA menyiapkan source dan menerapkan patch. Build kernelnya sendiri
REM butuh macOS (clang + cctools + SDK) - lihat docs\INSTALL-STEP-BY-STEP.md
REM Bagian C (build lewat GitHub Actions, gratis).
REM
REM Butuh Git Bash (biasanya sudah ada kalau kamu punya Git for Windows).
REM
REM Usage:
REM   xnu8020-prep.bat
REM   xnu8020-prep.bat --refetch     (hapus lalu unduh ulang)
REM ============================================================================

setlocal

echo.
echo ================================================
echo   HakiOS / tissot - XNU 8020 source prep
echo ================================================
echo.

REM ---- cari bash (Git Bash) ----
set BASH=
if exist "%ProgramFiles%\Git\bin\bash.exe" set BASH=%ProgramFiles%\Git\bin\bash.exe
if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set BASH=%ProgramFiles(x86)%\Git\bin\bash.exe
if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe
if "%BASH%"=="" (
    where bash >nul 2>&1
    if %ERRORLEVEL%==0 set BASH=bash
)

if "%BASH%"=="" (
    echo ERROR: Git Bash tidak ditemukan.
    echo        Install Git for Windows: https://git-scm.com/download/win
    echo        lalu jalankan ulang script ini.
    pause
    exit /b 1
)

echo   bash : %BASH%
echo.

echo [1/2] Menyiapkan source XNU 8020 + patch...
"%BASH%" "%~dp0xnu\apply-8020.sh" %1
if %ERRORLEVEL% neq 0 (
    echo.
    echo ERROR: gagal menyiapkan source. Lihat pesan di atas.
    pause
    exit /b 1
)

echo.
echo [2/2] Cek toolchain (diharapkan GAGAL di Windows - itu normal)...
"%BASH%" "%~dp0xnu-build-arm64.sh" --check

echo.
echo ================================================
echo   Selesai (source siap)
echo ================================================
echo.
echo   Source ada di : %~dp0xnu-src-8020
echo   Patch        : %~dp0xnu\patches-8020
echo.
echo   LANGKAH BERIKUTNYA - build kernel butuh macOS.
echo   Cara termudah (gratis): GitHub Actions.
echo.
echo     1. Push folder ini ke repo GitHub (boleh private)
echo     2. Tab "Actions" - workflow "xnu-tissot" - Run workflow
echo     3. Tunggu, lalu download artifact "xnu-tissot-kernel"
echo.
echo   Panduan lengkap: docs\INSTALL-STEP-BY-STEP.md (Bagian C)
echo.
pause

endlocal
