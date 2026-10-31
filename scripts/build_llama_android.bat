@echo off
setlocal EnableExtensions

set "ROOT=%~dp0.."
set "NDK=C:\Users\Administrator\AppData\Local\Android\Sdk\ndk\28.2.13676358"
set "CMAKE=C:\Users\Administrator\AppData\Local\Android\Sdk\cmake\4.1.2\bin\cmake.exe"
set "NINJA=C:\Users\Administrator\AppData\Local\Android\Sdk\cmake\4.1.2\bin\ninja.exe"
set "VULKAN_SDK_DIR=C:\VulkanSDK\1.4.363.0"
set "BUILD_DIR=%ROOT%\build\llama-android-arm64"
set "SYSROOT=%NDK%\toolchains\llvm\prebuilt\windows-x86_64\sysroot"

call "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" -arch=amd64 -host_arch=amd64 >nul
set "PATH=%VULKAN_SDK_DIR%\Bin;%CMAKE%\..\bin;%PATH%"

if /I "%~1"=="clean" (
    if exist "%BUILD_DIR%" rmdir /s /q "%BUILD_DIR%"
)

"%CMAKE%" -S "%ROOT%\third_party\llama.cpp" -B "%BUILD_DIR%" -G Ninja ^
  -DCMAKE_MAKE_PROGRAM="%NINJA%" ^
  -DCMAKE_TOOLCHAIN_FILE="%NDK%\build\cmake\android.toolchain.cmake" ^
  -DANDROID_ABI=arm64-v8a ^
  -DANDROID_PLATFORM=android-29 ^
  -DANDROID_STL=c++_static ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16 ^
  -DGGML_VULKAN=ON ^
  -DGGML_OPENMP=OFF ^
  -DGGML_NATIVE=OFF ^
  -DGGML_BACKEND_DL=OFF ^
  -DLLAMA_BUILD_COMMON=ON ^
  -DLLAMA_BUILD_EXAMPLES=ON ^
  -DLLAMA_BUILD_TOOLS=ON ^
  -DLLAMA_BUILD_TESTS=OFF ^
  -DLLAMA_BUILD_SERVER=OFF ^
  -DLLAMA_CURL=OFF ^
  -DVulkan_GLSLC_EXECUTABLE="%VULKAN_SDK_DIR%\Bin\glslc.exe" ^
  -DVulkan_INCLUDE_DIR="%VULKAN_SDK_DIR%\Include" ^
  -DVulkan_LIBRARY="%SYSROOT%\usr\lib\aarch64-linux-android\29\libvulkan.so" ^
  -DSPIRV-Headers_DIR="%VULKAN_SDK_DIR%\Lib\cmake\SPIRV-Headers"
if errorlevel 1 exit /b 1

"%CMAKE%" --build "%BUILD_DIR%" --target llama-simple llama-bench -j 20
if errorlevel 1 exit /b 1

echo BUILD_OK
