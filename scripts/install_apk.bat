@echo off
setlocal EnableExtensions

set "ADB=C:\Users\Administrator\AppData\Local\Android\Sdk\platform-tools\adb.exe"
set "ROOT=%~dp0.."
set "APK=%ROOT%\dist\edge-ai-arm64.apk"
if not exist "%APK%" set "APK=%ROOT%\app\build\app\outputs\flutter-apk\app-release.apk"
if not exist "%APK%" (
    echo APK not found. Run scripts\build_all.bat first.
    exit /b 1
)

"%ADB%" install -r --no-streaming "%APK%"
echo.
echo If vivo shows a security prompt, tick the checkbox and tap "Continue install".
