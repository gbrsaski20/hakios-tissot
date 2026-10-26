@echo off
REM ============================================================================
REM HakiOS-x86 WSL Setup Helper
REM
REM Walks you through installing WSL2 + Ubuntu step by step.
REM Run this if you are unsure whether WSL is ready.
REM
REM Usage: setup-wsl.bat
REM ============================================================================

setlocal

echo ============================================
echo  HakiOS-x86 - WSL2 Setup Helper
echo ============================================
echo.

REM ---- Check 1: WSL command exists ----
echo [1/4] Checking WSL command...
wsl --status >nul 2>&1
if errorlevel 1 (
    echo   WSL is NOT available.
    echo.
    echo   FIX: Open PowerShell as Administrator and run:
    echo     wsl --install -d Ubuntu
    echo   Then RESTART Windows and run this script again.
    echo.
    pause
    exit /b 1
)
echo   WSL is available. OK.
echo.

REM ---- Check 2: List distros ----
echo [2/4] Checking installed distros...
set FOUND=
for /f "tokens=*" %%d in ('wsl -l -q 2^>nul') do (
    if not "%%d"=="" (
        echo   - %%d
        if not defined FOUND set FOUND=%%d
    )
)
if not defined FOUND (
    echo   No distro installed.
    echo.
    echo   FIX: Open PowerShell as Administrator and run:
    echo     wsl --install -d Ubuntu
    echo   Then RESTART Windows.
    echo.
    pause
    exit /b 1
)
echo.

REM ---- Check 3: Does the distro actually run? ----
echo [3/4] Testing if the distro starts...
wsl -d %FOUND% -e bash -c "echo HAKIOS_PROBE_OK" >nul 2>&1
if errorlevel 1 (
    echo   Distro '%FOUND%' is installed but NOT initialized.
    echo.
    echo   FIX:
    echo     1. Restart Windows if you have not done so
    echo     2. Launch '%FOUND%' from the Start Menu
    echo     3. Create username and password
    echo     4. Type 'exit' to close
    echo     5. Run this script again
    echo.
    pause
    exit /b 1
)
echo   Distro '%FOUND%' runs correctly. OK.
echo.

REM ---- Check 4: Build tools ----
echo [4/4] Checking build tools...
wsl -d %FOUND% -e bash -c "command -v clang >/dev/null 2>&1 && command -v lld-link >/dev/null 2>&1" >nul 2>&1
if errorlevel 1 (
    echo   clang and/or lld are missing.
    echo   They will be installed automatically by build-windows.bat.
) else (
    echo   Build tools present. OK.
)
echo.

echo ============================================
echo  WSL is ready.
echo ============================================
echo.
echo Now run:
echo   build-windows.bat
echo.
pause
