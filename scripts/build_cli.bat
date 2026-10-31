@echo off
setlocal EnableExtensions

rem Build the llama.cpp CLI tools used to validate the device backends.
call "%~dp0build_llama_android.bat" %*
if errorlevel 1 exit /b 1

echo.
echo CLI binaries:
echo   build\llama-android-arm64\bin\llama-simple
echo   build\llama-android-arm64\bin\llama-bench
