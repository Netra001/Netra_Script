@echo off
REM ====================================================================
REM  Build PlatformCode Delete GUI into a single Windows .exe
REM  Run this from the folder containing:
REM      platform_delete_gui.py
REM      PlatformDelete-Backend.ps1
REM ====================================================================

echo.
echo ============================================================
echo  PLATFORMCODE DELETE - EXE BUILD
echo ============================================================
echo.

if not exist "platform_delete_gui.py" (
    echo ERROR: platform_delete_gui.py not found in this folder.
    pause
    exit /b 1
)

if not exist "PlatformDelete-Backend.ps1" (
    echo ERROR: PlatformDelete-Backend.ps1 not found in this folder.
    pause
    exit /b 1
)

echo Installing / verifying PyInstaller...
python -m pip install --upgrade pyinstaller
if errorlevel 1 (
    echo ERROR: Could not install PyInstaller.
    pause
    exit /b 1
)

if exist "build"  rmdir /s /q "build"
if exist "dist"   rmdir /s /q "dist"
if exist "PlatformDelete.spec" del /q "PlatformDelete.spec"

echo.
echo Building executable...
echo.

pyinstaller ^
    --onefile ^
    --windowed ^
    --name PlatformDelete ^
    --add-data "PlatformDelete-Backend.ps1;." ^
    platform_delete_gui.py

if errorlevel 1 (
    echo.
    echo 'pyinstaller' command failed or was not found - retrying via
    echo 'python -m PyInstaller' instead...
    echo.

    python -m PyInstaller ^
        --onefile ^
        --windowed ^
        --name PlatformDelete ^
        --add-data "PlatformDelete-Backend.ps1;." ^
        platform_delete_gui.py
)

if errorlevel 1 (
    echo.
    echo ERROR: Build failed. See the messages above.
    pause
    exit /b 1
)

copy /y "PlatformDelete-Backend.ps1" "dist\" >nul

echo.
echo ============================================================
echo  BUILD COMPLETE
echo ============================================================
echo.
echo  Executable : dist\PlatformDelete.exe
echo.
echo  Copy the whole dist\ folder to the target server and run
echo  PlatformDelete.exe from there.
echo.
pause
