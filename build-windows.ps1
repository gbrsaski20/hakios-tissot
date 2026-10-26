<#
.SYNOPSIS
    HakiOS-x86 Build Script for Windows (WSL2)
.DESCRIPTION
    Builds HakiOS-x86 entirely inside WSL2, then copies the resulting
    binaries back to the Windows host. No manual Linux setup needed.

    This script handles the whole lifecycle:
      1. Detect WSL and pick a working distro
      2. Install the distro if missing
      3. Detect an uninitialized distro and guide you through first launch
      4. Install build dependencies (runs as root inside WSL)
      5. Run the build
      6. Report where the binaries landed
.PARAMETER Mode
    "open"  - Build open kernel + loader (no iOS IPSW needed) [default]
    "full"  - Build full system (downloads iOS 16.5 IPSW)
.PARAMETER Clean
    Clean previous build artifacts before building.
.PARAMETER Distro
    WSL distro to use. "auto" (default) picks the first available one.
.EXAMPLE
    .\build-windows.ps1                 # builds open mode
    .\build-windows.ps1 full            # builds full mode
    .\build-windows.ps1 open -Clean     # clean + build open
    .\build-windows.ps1 -Distro Ubuntu-24.04
#>

param(
    [ValidateSet("open", "full")]
    [string]$Mode = "open",
    [switch]$Clean,
    [switch]$Rufus,
    [string]$Distro = "auto"
)

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = $ScriptDir

# ---- Log everything to a file so errors are never lost ----
$logDir = Join-Path $ProjectDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir "build-windows.log"
try { Start-Transcript -Path $logFile -Append -Force | Out-Null } catch { }

# ---- Global safety net: never close without a pause ----
trap {
    Write-Host ""
    Write-Host "!!! UNEXPECTED ERROR: $_" -ForegroundColor Red
    Write-Host "    See log: $logFile" -ForegroundColor Yellow
    Write-Host ""
    pause
}

function Write-Step($n, $total, $msg) {
    Write-Host "[$n/$total] $msg" -ForegroundColor Green
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  HakiOS-x86 Build (Windows + WSL2)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Mode:   $Mode" -ForegroundColor Yellow
Write-Host "  Clean:  $($Clean.IsPresent)" -ForegroundColor Yellow
Write-Host "  Rufus:  $($Rufus.IsPresent)" -ForegroundColor Yellow
Write-Host ""

$Total = 6

# ============================================================================
# Step 1: Check WSL
# ============================================================================
Write-Step 1 $Total "Checking WSL..."

$wslVer = wsl --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: WSL is not available." -ForegroundColor Red
    Write-Host ""
    Write-Host "Fix (run PowerShell as Administrator):" -ForegroundColor Yellow
    Write-Host "  wsl --install -d Ubuntu" -ForegroundColor White
    Write-Host "  then restart Windows" -ForegroundColor White
    Write-Host ""
    pause
    exit 1
}
Write-Host "  WSL available." -ForegroundColor Gray

# ============================================================================
# Step 2: Pick a distro
# ============================================================================
Write-Step 2 $Total "Checking WSL distros..."

$rawList = wsl -l -q 2>$null
$installed = @()
foreach ($line in $rawList) {
    $t = $line.Trim()
    if ($t) { $installed += $t }
}

if ($installed.Count -eq 0) {
    Write-Host "  No distro installed." -ForegroundColor Yellow
    $answer = Read-Host "  Install Ubuntu now? (Y/n)"
    if ($answer -match '^[Nn]') {
        Write-Host "  Aborted. Run: wsl --install -d Ubuntu" -ForegroundColor Red
        pause
        exit 1
    }

    Write-Host "  Installing Ubuntu (may take a few minutes)..." -ForegroundColor Gray
    wsl --install -d Ubuntu

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  Ubuntu installed." -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "   1. RESTART Windows (required for WSL to activate)" -ForegroundColor White
    Write-Host "   2. Launch 'Ubuntu' from the Start Menu" -ForegroundColor White
    Write-Host "   3. Create your username and password" -ForegroundColor White
    Write-Host "   4. Run this script again" -ForegroundColor White
    Write-Host ""
    pause
    exit 0
}

# Choose which distro to use
if ($Distro -eq "auto") {
    $Distro = $installed[0]
} elseif ($installed -notcontains $Distro) {
    Write-Host "  Distro '$Distro' not found. Available:" -ForegroundColor Yellow
    $installed | ForEach-Object { Write-Host "    - $_" -ForegroundColor White }
    $Distro = $installed[0]
    Write-Host "  Using '$Distro' instead." -ForegroundColor Yellow
}
Write-Host "  Using distro: $Distro" -ForegroundColor Gray

# ============================================================================
# Step 3: Verify the distro actually runs (catches uninitialized distros)
# ============================================================================
Write-Step 3 $Total "Verifying distro works..."

$probe = wsl -d $Distro -e bash -c "echo HAKIOS_OK" 2>&1
if ($probe -notmatch "HAKIOS_OK") {
    Write-Host ""
    Write-Host "The distro '$Distro' is installed but has not been set up yet." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This is normal after a fresh install. Please:" -ForegroundColor White
    Write-Host "  1. Restart Windows if you have not done so yet" -ForegroundColor White
    Write-Host "  2. Launch '$Distro' from the Start Menu" -ForegroundColor White
    Write-Host "  3. Create your username and password" -ForegroundColor White
    Write-Host "  4. Run this script again" -ForegroundColor White
    Write-Host ""
    Write-Host "Error detail: $probe" -ForegroundColor DarkGray
    Write-Host ""
    pause
    exit 1
}
Write-Host "  Distro responds." -ForegroundColor Gray

# ============================================================================
# Step 4: Convert path, install dependencies
# ============================================================================
$wslProjectDir = ($ProjectDir -replace '\\', '/') -replace '^([A-Za-z]):', '/mnt/$1' -replace '//', '/'
$wslProjectDir = $wslProjectDir.ToLower()

Write-Step 4 $Total "Installing build dependencies (inside WSL)..."

# NOTE: we run as root so sudo never prompts for a password
$setupScript = @"
set -e
cd '$wslProjectDir'
chmod +x xnu-deps/setup.sh xnu/apply.sh xnu-build-x86.sh xnuloader/build.sh \
         userland/build.sh qemu/run-x86.sh tools/*.sh sysimage/fetch.sh 2>/dev/null || true
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>&1 | tail -1
apt-get install -y -qq clang lld lz4 p7zip-full qemu-system-x86 qemu-utils \
    git make python3 python3-pip parted dosfstools mtools build-essential \
    binutils file xz-utils bzip2 gzip 2>&1 | tail -3
echo '--- versions ---'
clang --version | head -1
ld.lld --version | head -1
qemu-system-x86_64 --version | head -1
echo SETUP_DONE
"@

try {
    $setupOut = wsl -d $Distro -u root -e bash -c $setupScript 2>&1
    $setupOut | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    if ($setupOut -match "SETUP_DONE") {
        Write-Host "  Dependencies ready." -ForegroundColor Gray
    } else {
        Write-Host "  WARNING: dependency install may have partially failed." -ForegroundColor Yellow
        Write-Host "  The build will still be attempted." -ForegroundColor Gray
    }
} catch {
    Write-Host "  ERROR during dependency install: $_" -ForegroundColor Red
    Write-Host "  Will attempt the build anyway." -ForegroundColor Yellow
}

# ============================================================================
# Step 5: Build
# ============================================================================
Write-Step 5 $Total "Building HakiOS-x86 ($Mode mode)..."

$buildTarget = if ($Mode -eq "full") { "x86-full" } else { "x86-open" }
$cleanPart = if ($Clean.IsPresent) { "clean && " } else { "" }

$buildScript = @"
cd '$wslProjectDir' || exit 1
$cleanPart make $buildTarget 2>&1
echo "BUILD_EXIT_CODE=`$?"
"@

try {
    $buildOut = wsl -d $Distro -e bash -c $buildScript 2>&1
    $buildOut | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

    if ($buildOut -match "BUILD_EXIT_CODE=0") {
        Write-Host "  Build succeeded." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  Build failed. See the output above for the error." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Common fixes:" -ForegroundColor Yellow
        Write-Host "   - Build the loader only (no SDK needed):" -ForegroundColor White
        Write-Host "       cd $wslProjectDir && ./xnuloader/build.sh" -ForegroundColor White
        Write-Host "   - XNU kernel needs cctools + macOS SDK (hard on Linux)." -ForegroundColor White
        Write-Host "     If only the kernel failed, the loader may still be built." -ForegroundColor White
        Write-Host ""
        Write-Host "  Log saved to: $logFile" -ForegroundColor Yellow
        pause
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "  ERROR during build: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Common fixes:" -ForegroundColor Yellow
    Write-Host "   - Build the loader only (no SDK needed):" -ForegroundColor White
    Write-Host "       cd $wslProjectDir && ./xnuloader/build.sh" -ForegroundColor White
    Write-Host "   - XNU kernel needs cctools + macOS SDK (hard on Linux)." -ForegroundColor White
    Write-Host "     If only the kernel failed, the loader may still be built." -ForegroundColor White
    Write-Host ""
    Write-Host "  Log saved to: $logFile" -ForegroundColor Yellow
    pause
    exit 1
}

# ============================================================================
# Step 6: Report results
# ============================================================================
Write-Step 6 $Total "Checking build output..."

$prebuiltWin = Join-Path $ProjectDir "prebuilt"
$found = $false

if (Test-Path $prebuiltWin) {
    $items = Get-ChildItem $prebuiltWin -File | Where-Object { $_.Name -ne "README.md" }
    if ($items) {
        $found = $true
        Write-Host "  Binaries in prebuilt\:" -ForegroundColor Green
        foreach ($i in $items) {
            $sizeKB = [math]::Round($i.Length / 1KB, 1)
            Write-Host ("    {0,-32} {1} KB" -f $i.Name, $sizeKB) -ForegroundColor White
        }
    }
}

if (-not $found) {
    Write-Host "  No binaries produced yet." -ForegroundColor Yellow
    Write-Host "  Try building the loader alone:" -ForegroundColor Yellow
    Write-Host "    wsl -d $Distro -e bash -c 'cd $wslProjectDir && ./xnuloader/build.sh'" -ForegroundColor White
}

# ============================================================================
# Step 6b: Create Rufus-flashable image (if -Rufus)
# ============================================================================
if ($Rufus.IsPresent) {
    Write-Step "6b" $Total "Creating Rufus-flashable image..."

    $rufusScript = @"
cd '$wslProjectDir' || exit 1
chmod +x tools/make-rufus-img.sh 2>/dev/null || true
tools/make-rufus-img.sh prebuilt/hakios-x86.img 2>&1
echo "RUFUS_EXIT_CODE=`$?"
"@

    try {
        $rufusOut = wsl -d $Distro -e bash -c $rufusScript 2>&1
        $rufusOut | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

        if ($rufusOut -match "RUFUS_EXIT_CODE=0") {
            $imgWin = Join-Path $ProjectDir "prebuilt\hakios-x86.img"
            if (Test-Path $imgWin) {
                $imgSize = [math]::Round((Get-Item $imgWin).Length / 1MB, 1)
                Write-Host "  Rufus image: prebuilt\hakios-x86.img ($imgSize MB)" -ForegroundColor Green
            }
        } else {
            Write-Host "  Rufus image creation failed." -ForegroundColor Red
            Write-Host "  Try manually: make-rufus-img.bat" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ERROR creating Rufus image: $_" -ForegroundColor Red
        Write-Host "  Try manually: make-rufus-img.bat" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Done." -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Run in QEMU:" -ForegroundColor Yellow
Write-Host "  .\run-qemu-windows.bat" -ForegroundColor White
Write-Host ""
Write-Host "Or manually:" -ForegroundColor White
Write-Host "  wsl -d $Distro -e bash -c 'cd $wslProjectDir && make qemu-open'" -ForegroundColor White
Write-Host ""

if ($Rufus.IsPresent -and (Test-Path (Join-Path $ProjectDir "prebuilt\hakios-x86.img"))) {
    Write-Host "Flash to USB with Rufus:" -ForegroundColor Yellow
    Write-Host "  1. Open Rufus (https://rufus.ie)" -ForegroundColor White
    Write-Host "  2. SELECT: prebuilt\hakios-x86.img" -ForegroundColor White
    Write-Host "  3. Partition: GPT, Target: UEFI (non-CSM)" -ForegroundColor White
    Write-Host "  4. START (choose DD Image mode if asked)" -ForegroundColor White
    Write-Host "  5. Boot from USB" -ForegroundColor White
    Write-Host ""
} else {
    Write-Host "Bootable USB (Linux only, needs a real USB device):" -ForegroundColor Yellow
    Write-Host "  wsl -d $Distro -e bash -c 'cd $wslProjectDir && sudo tools/make-boot-usb.sh /dev/sdX'" -ForegroundColor White
    Write-Host ""
    Write-Host "Or create a Rufus-flashable image:" -ForegroundColor Yellow
    Write-Host "  .\make-rufus-img.bat" -ForegroundColor White
    Write-Host ""
}
pause
