@echo off
setlocal EnableExtensions

set "ROOT=%~dp0.."
set "NDK=C:\Users\Administrator\AppData\Local\Android\Sdk\ndk\28.2.13676358"
set "CMAKE=C:\Users\Administrator\AppData\Local\Android\Sdk\cmake\4.1.2\bin\cmake.exe"
set "NINJA=C:\Users\Administrator\AppData\Local\Android\Sdk\cmake\4.1.2\bin\ninja.exe"
set "VULKAN_SDK_DIR=C:\VulkanSDK\1.4.363.0"
set "BUILD_DIR=%ROOT%\build\native-android-x86_64"
set "SYSROOT=%NDK%\toolchains\llvm\prebuilt\windows-x86_64\sysroot"
set "JNI_DIR=%ROOT%\app\android\app\src\main\jniLibs\x86_64"

call "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" -arch=amd64 -host_arch=amd64 >nul
set "PATH=%VULKAN_SDK_DIR%\Bin;%PATH%"

if /I "%~1"=="clean" (
    if exist "%BUILD_DIR%" rmdir /s /q "%BUILD_DIR%"
)

"%CMAKE%" -S "%ROOT%\native" -B "%BUILD_DIR%" -G Ninja ^
  -DCMAKE_MAKE_PROGRAM="%NINJA%" ^
  -DCMAKE_TOOLCHAIN_FILE="%NDK%\build\cmake\android.toolchain.cmake" ^
  -DANDROID_ABI=x86_64 ^
  -DANDROID_PLATFORM=android-29 ^
  -DANDROID_STL=c++_static ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DVulkan_GLSLC_EXECUTABLE="%VULKAN_SDK_DIR%\Bin\glslc.exe" ^
  -DVulkan_INCLUDE_DIR="%VULKAN_SDK_DIR%\Include" ^
  -DVulkan_LIBRARY="%SYSROOT%\usr\lib\x86_64-linux-android\29\libvulkan.so" ^
  -DSPIRV-Headers_DIR="%VULKAN_SDK_DIR%\Lib\cmake\SPIRV-Headers"
if errorlevel 1 exit /b 1

"%CMAKE%" --build "%BUILD_DIR%" --target edge_ai edge_ai_smoke -j 20
if errorlevel 1 exit /b 1

if not exist "%JNI_DIR%" mkdir "%JNI_DIR%"
copy /Y "%BUILD_DIR%\out\libedge_ai.so" "%JNI_DIR%\libedge_ai.so" >nul
"%NDK%\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe" --strip-unneeded "%JNI_DIR%\libedge_ai.so"
echo X86_64_NATIVE_OK
