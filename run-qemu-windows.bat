@echo off
REM ============================================================================
REM HakiOS-x86 QEMU Runner for Windows (WSL2)
REM
REM Runs HakiOS-x86 in QEMU from inside WSL2.
REM Usage:
REM   run-qemu-windows.bat          Run open mode (default)
REM   run-qemu-windows.bat full     Run full iOS user space
REM   run-qemu-windows.bat 600      Run for 600 seconds
REM ============================================================================

setlocal enabledelayedexpansion
set MODE=--open
set SECS=1200
set DISTRO=auto
set PROJECT_WIN=%~dp0

:parse
if "%~1"=="" goto run
if /i "%~1"=="full" (
    set MODE=
    set FULLFLAG=1
    shift
    goto parse
)
if /i "%~1"=="open" (
    set MODE=--open
    shift
    goto parse
)
echo %~1 | findstr /r "^[0-9][0-9]*$" >nul 2>&1
if not errorlevel 1 (
    set SECS=%~1
    shift
    goto parse
)
shift
goto parse

:run
echo HakiOS-x86 QEMU Runner (Windows -^> WSL2)
echo.

REM ---- Detect a distro ----
if "%DISTRO%"=="auto" (
    for /f "tokens=*" %%d in ('wsl -l -q 2^>nul') do (
        if not defined FOUND_DISTRO (
            set "DISTRO=%%d"
            set FOUND_DISTRO=1
        )
    )
)
if not defined DISTRO (
    echo ERROR: No WSL distro found. Run build-windows.bat first.
    exit /b 1
)
echo Distro: %DISTRO%

REM ---- Convert the Windows project path to a WSL path ----
REM Strip the trailing backslash, then E:\foo -> /mnt/e/foo
set "PSCRIPT=%PROJECT_WIN:~0,-1%"
set "PSCRIPT=%PSCRIPT:\=/%"
set "PSCRIPT=/mnt/%PSCRIPT:~0,1%/%PSCRIPT:~3%"
for /f "tokens=1 delims=:" %%a in ('echo %PSCRIPT%') do set "PSCRIPT=%%a"

echo Project: %PSCRIPT%
echo.

if defined FULLFLAG (
    echo Running FULL mode (iOS user space)...
    wsl -d "%DISTRO%" -e bash -c "cd '%PSCRIPT%' && make qemu"
) else (
    echo Running OPEN mode for %SECS% seconds...
    wsl -d "%DISTRO%" -e bash -c "cd '%PSCRIPT%' && qemu/run-x86.sh %SECS% --open"
)

endlocal
