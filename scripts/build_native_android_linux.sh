#!/usr/bin/env bash
# Cross-compile libedge_ai.so on a Linux host / GitHub Actions.
# Usage: build_native_android_linux.sh [arm64-v8a|x86_64]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ABI="${1:-arm64-v8a}"

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  ANDROID_NDK_HOME="${ANDROID_NDK:-${ANDROID_HOME:-}/ndk/28.2.13676358}"
fi
if [[ ! -d "$ANDROID_NDK_HOME" ]]; then
  echo "Android NDK not found. Set ANDROID_NDK_HOME." >&2
  exit 1
fi

CMAKE="${CMAKE:-${ANDROID_HOME:-}/cmake/4.1.2/bin/cmake}"
NINJA="${NINJA:-${ANDROID_HOME:-}/cmake/4.1.2/bin/ninja}"
if [[ ! -x "$CMAKE" ]]; then CMAKE="$(command -v cmake)"; fi
if [[ ! -x "$NINJA" ]]; then NINJA="$(command -v ninja)"; fi

GLSLC="${GLSLC:-$(command -v glslc || true)}"
if [[ -z "$GLSLC" ]]; then
  echo "glslc not found. Install glslang-tools." >&2
  exit 1
fi

HOST_TAG="linux-x86_64"
SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG/sysroot"
STRIP="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG/bin/llvm-strip"

case "$ABI" in
  arm64-v8a)
    TRIPLE="aarch64-linux-android"
    JNI_DIR="$ROOT/app/android/app/src/main/jniLibs/arm64-v8a"
    ARCH_ARGS=(-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16)
    ;;
  x86_64)
    TRIPLE="x86_64-linux-android"
    JNI_DIR="$ROOT/app/android/app/src/main/jniLibs/x86_64"
    ARCH_ARGS=()
    ;;
  *)
    echo "Unsupported ABI: $ABI" >&2
    exit 1
    ;;
esac

VULKAN_LIB="$SYSROOT/usr/lib/$TRIPLE/29/libvulkan.so"
VULKAN_INCLUDE="${VULKAN_INCLUDE_DIR:-/usr/include}"
SPIRV_CMAKE_ARGS=()
for d in "${SPIRV_HEADERS_DIR:-}" /usr/lib/cmake/SPIRV-Headers /usr/share/cmake/SPIRV-Headers; do
  if [[ -n "$d" && -f "$d/SPIRV-HeadersConfig.cmake" ]]; then
    SPIRV_CMAKE_ARGS=(-DSPIRV-Headers_DIR="$d")
    break
  fi
done
if [[ ${#SPIRV_CMAKE_ARGS[@]} -eq 0 ]]; then
  FOUND_SPIRV="$(find /usr -name SPIRV-HeadersConfig.cmake -print -quit 2>/dev/null || true)"
  if [[ -n "$FOUND_SPIRV" ]]; then
    SPIRV_CMAKE_ARGS=(-DSPIRV-Headers_DIR="$(dirname "$FOUND_SPIRV")")
  fi
fi

BUILD_DIR="$ROOT/build/native-android-$ABI"

"$CMAKE" -S "$ROOT/native" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM=android-29 \
  -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  "${ARCH_ARGS[@]}" \
  -DVulkan_GLSLC_EXECUTABLE="$GLSLC" \
  -DVulkan_INCLUDE_DIR="$VULKAN_INCLUDE" \
  -DVulkan_LIBRARY="$VULKAN_LIB" \
  "${SPIRV_CMAKE_ARGS[@]}"

"$CMAKE" --build "$BUILD_DIR" --target edge_ai -j "${JOBS:-$(nproc)}"

mkdir -p "$JNI_DIR"
cp "$BUILD_DIR/out/libedge_ai.so" "$JNI_DIR/libedge_ai.so"
"$STRIP" --strip-unneeded "$JNI_DIR/libedge_ai.so"
echo "NATIVE_OK ($ABI)"
