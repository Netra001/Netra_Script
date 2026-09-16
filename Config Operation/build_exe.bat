@echo off
REM ====================================================================
REM  Build ConfigOperations GUI into a single Windows .exe
REM  Run this from the folder containing:
REM      config_operations_gui.py
REM      ConfigOperations-Backend.ps1
REM ====================================================================

echo.
echo ============================================================
echo  CONFIG OPERATIONS - EXE BUILD
echo ============================================================
echo.

REM --- Check the required files are present -------------------------
if not exist "config_operations_gui.py" (
    echo ERROR: config_operations_gui.py not found in this folder.
    pause
    exit /b 1
)

if not exist "ConfigOperations-Backend.ps1" (
    echo ERROR: ConfigOperations-Backend.ps1 not found in this folder.
    pause
    exit /b 1
)

REM --- Install PyInstaller if missing -------------------------------
echo Installing / verifying PyInstaller...
python -m pip install --upgrade pyinstaller
if errorlevel 1 (
    echo ERROR: Could not install PyInstaller.
    pause
    exit /b 1
)

REM --- Clean previous build -----------------------------------------
if exist "build"  rmdir /s /q "build"
if exist "dist"   rmdir /s /q "dist"
if exist "ConfigOperations.spec" del /q "ConfigOperations.spec"

REM --- Build ---------------------------------------------------------
REM  --onefile    : single executable
REM  --windowed   : no console window (GUI app)
REM  --add-data   : bundle the PowerShell backend inside the exe
echo.
echo Building executable...
echo.

pyinstaller ^
    --onefile ^
    --windowed ^
    --name ConfigOperations ^
    --add-data "ConfigOperations-Backend.ps1;." ^
    config_operations_gui.py

if errorlevel 1 (
    echo.
    echo 'pyinstaller' command failed or was not found - retrying via
    echo 'python -m PyInstaller' instead...
    echo.

    python -m PyInstaller ^
        --onefile ^
        --windowed ^
        --name ConfigOperations ^
        --add-data "ConfigOperations-Backend.ps1;." ^
        config_operations_gui.py
)

if errorlevel 1 (
    echo.
    echo ERROR: Build failed. See the messages above.
    pause
    exit /b 1
)

REM --- Copy the backend next to the exe as well ----------------------
REM  Belt and braces: the exe extracts its own copy at runtime, but a
REM  sibling copy makes the backend easy to inspect or patch.
copy /y "ConfigOperations-Backend.ps1" "dist\" >nul

echo.
echo ============================================================
echo  BUILD COMPLETE
echo ============================================================
echo.
echo  Executable : dist\ConfigOperations.exe
echo.
echo  Copy the whole dist\ folder to the target server and run
echo  ConfigOperations.exe from there.
echo.
pause
