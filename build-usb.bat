@echo off
:: =============================================================================
:: PPSA - Build Portable USB Appliance Image
:: =============================================================================
:: This batch file builds a bootable Debian disk image (.img) for USB SSD.
:: The image contains a complete Debian system with Docker + PPSA stack
:: pre-installed. Write it to a USB SSD with Rufus (DD mode) and boot.
::
:: Requires: Docker Desktop for Windows (free), 8GB+ free disk space
::   No WSL required. Docker provides the Linux builder environment.
::
:: Usage:    build-usb.bat
:: =============================================================================
setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
set BUILD_DIR=%SCRIPT_DIR%build
set OUTPUT_IMG=%BUILD_DIR%\ppsa-usb.img
set BUILDER_TAG=ppsa-builder

cls
echo =============================================================================
echo  PPSA - Portable Palworld Server Appliance USB Builder
echo =============================================================================
echo.
echo  This builds a bootable Debian disk image that runs entirely from a USB SSD.
echo  No installation to internal disk required -- just plug, boot, and play.
echo.

:: Check for Docker Desktop
docker info >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Docker is not running or not installed.
    echo Install Docker Desktop from: https://www.docker.com/products/docker-desktop/
    echo Then launch Docker Desktop and wait for it to start.
    exit /b 1
)

:: Create build directory
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

:: Check if build script exists
if not exist "%SCRIPT_DIR%scripts\build-live-usb.sh" (
    echo [ERROR] scripts\build-live-usb.sh not found.
    exit /b 1
)

:: Build the builder image if needed (or outdated)
echo [1/3] Checking builder image...
docker images -q %BUILDER_TAG% >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo  Building ppsa-builder image (~3 min first time)...
    docker build -t %BUILDER_TAG% -f Dockerfile.build "%SCRIPT_DIR%"
    if !ERRORLEVEL! neq 0 (
        echo [ERROR] Failed to build builder image.
        exit /b 1
    )
) else (
    echo  Builder image exists.
)

echo.
echo =============================================================================
echo  Building PPSA USB image...
echo  This will download packages and create a ~4GB disk image.
echo  Internet connection required. May take 10-30 minutes depending on speed.
echo =============================================================================
echo.

echo [2/3] Launching Docker builder (privileged mode for loop/mount)...
docker run --rm ^
    --privileged ^
    -v "%SCRIPT_DIR%:/workspace" ^
    -w /workspace ^
    %BUILDER_TAG% ^
    bash scripts/build-live-usb.sh --output "/workspace/build/ppsa-usb.img"

if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERROR] Build failed. Check the output above for details.
    echo Common issues:
    echo   - Docker Desktop needs at least 8GB free disk space
    echo   - Slow or no internet connection
    echo   - Try: docker build --no-cache -t ppsa-builder -f Dockerfile.build .
    exit /b 1
)

echo.
echo =============================================================================
echo  SUCCESS!
echo =============================================================================
echo.
echo  Output image: %OUTPUT_IMG%
echo  Size:         ~4GB (will expand to fill your USB SSD)
echo.
echo  Next steps:
echo  1. Download Rufus: https://rufus.ie
echo  2. Insert your USB SSD (WARNING: ALL DATA WILL BE DESTROYED)
echo  3. Open Rufus, select the USB drive
echo  4. Click "SELECT" and choose: %OUTPUT_IMG%
echo  5. Important: Click "START" and when asked about mode,
echo     choose "Write in DD Image mode"
echo  6. Wait for Rufus to finish
echo  7. Boot the target PC from this USB SSD
echo     - Enter BIOS boot menu (usually F12, F2, Del, or Esc)
echo     - Select the USB SSD (not UEFI:USB, just USB)
echo  8. Debian boots directly from the USB
echo  9. Complete first-boot setup via the web interface
echo     http://(server-ip):8080   (DHCP will assign an IP)
echo.
echo  Note: For reliable operation, use a USB 3.0+ SSD (not a flash drive).
echo  Minimum recommended: 64GB USB SSD.
echo =============================================================================

endlocal
