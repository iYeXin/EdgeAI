@echo off
setlocal EnableExtensions

set "ROOT=%~dp0.."
set "FLUTTER=D:\App\flutter_sdk\flutter\bin\flutter.bat"

call "%~dp0build_native_android.bat"
if errorlevel 1 exit /b 1

pushd "%ROOT%\app"
call "%FLUTTER%" build apk --release --target-platform android-arm64
set "RESULT=%ERRORLEVEL%"
popd
if not "%RESULT%"=="0" exit /b %RESULT%

if not exist "%ROOT%\dist" mkdir "%ROOT%\dist"
copy /Y "%ROOT%\app\build\app\outputs\flutter-apk\app-release.apk" "%ROOT%\dist\edge-ai-arm64.apk" >nul
echo APK: %ROOT%\dist\edge-ai-arm64.apk
