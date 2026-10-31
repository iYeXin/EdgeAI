@echo off
setlocal EnableExtensions

set "ADB=C:\Users\Administrator\AppData\Local\Android\Sdk\platform-tools\adb.exe"
set "PKG=com.edgeai.edge_ai"
set "MODEL=%~1"
if "%MODEL%"=="" set "MODEL=C:\Users\Administrator\.lmstudio\models\lmstudio-community\Qwen3-1.7B-GGUF\Qwen3-1.7B-Q6_K.gguf"
set "REMOTE=/sdcard/Android/data/%PKG%/files/models"

if not exist "%MODEL%" (
    echo Model not found: %MODEL%
    exit /b 1
)

for /f "delims=" %%i in ('"%ADB%" shell pm path %PKG% 2^>nul') do set "INSTALLED=1"
if not defined INSTALLED (
    echo Install the app first: scripts\install_apk.bat
    exit /b 1
)

rem The app must create this directory itself. A shell-created directory is
rem invisible to the app because of Android scoped-storage ownership.
echo Launching the app once to create its external files directory...
"%ADB%" shell am start -n %PKG%/.MainActivity >nul
timeout /t 5 /nobreak >nul
"%ADB%" shell am force-stop %PKG%

"%ADB%" shell mkdir -p "%REMOTE%"
echo Copying model once, about 1.56 GiB...
"%ADB%" push "%MODEL%" "%REMOTE%/"
if errorlevel 1 exit /b 1

"%ADB%" shell ls -l "%REMOTE%"
echo.
echo Model is on the device. Open Edge AI again; it loads the GGUF automatically.
