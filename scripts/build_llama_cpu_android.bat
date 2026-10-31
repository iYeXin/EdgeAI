@echo off
setlocal EnableExtensions
set "ROOT=%~dp0.."
set "NDK=C:\Users\Administrator\AppData\Local\Android\Sdk\ndk\28.2.13676358"
set "CMAKE=C:\Users\Administrator\AppData\Local\Android\Sdk\cmake\4.1.2\bin\cmake.exe"
set "NINJA=C:\Users\Administrator\AppData\Local\Android\Sdk\cmake\4.1.2\bin\ninja.exe"
set "BUILD_DIR=%ROOT%\build\llama-android-cpu"
call "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" -arch=amd64 -host_arch=amd64 >nul
"%CMAKE%" -S "%ROOT%\third_party\llama.cpp" -B "%BUILD_DIR%" -G Ninja ^
  -DCMAKE_MAKE_PROGRAM="%NINJA%" ^
  -DCMAKE_TOOLCHAIN_FILE="%NDK%\build\cmake\android.toolchain.cmake" ^
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DANDROID_STL=c++_static ^
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF ^
  -DGGML_VULKAN=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=OFF ^
  -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16 ^
  -DLLAMA_BUILD_COMMON=ON -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_TOOLS=ON ^
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_CURL=OFF
if errorlevel 1 exit /b 1
"%CMAKE%" --build "%BUILD_DIR%" --target llama-bench -j 20
if errorlevel 1 exit /b 1
echo CPU_BUILD_OK
