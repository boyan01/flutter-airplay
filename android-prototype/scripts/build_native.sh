#!/usr/bin/env bash
set -euo pipefail
module="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$module/.." && pwd)"
: "${ANDROID_HOME:?Set ANDROID_HOME to an installed SDK}"
ndk="$ANDROID_HOME/ndk/${NDK_VERSION:-28.2.13676358}"
cmake="$ANDROID_HOME/cmake/3.22.1/bin/cmake"
case "$(uname -s)" in Darwin) host=darwin-x86_64 ;; Linux) host=linux-x86_64 ;; *) exit 1 ;; esac
export ANDROID_NDK_ROOT="$ndk"
export PATH="$ndk/toolchains/llvm/prebuilt/$host/bin:$PATH"
python3 "$module/scripts/fetch_deps.py"
python3 "$module/scripts/prepare_core.py"
mkdir -p "$root/artifacts/android"
if [[ $# -eq 0 ]]; then set -- arm64-v8a x86_64; fi
for abi in "$@"; do
    case "$abi" in arm64-v8a) ssl_target=android-arm64 ;; x86_64) ssl_target=android-x86_64 ;; *) echo "Unsupported ABI: $abi"; exit 1 ;; esac
    prefix="$module/.cache/crypto-$abi"
    ssl_build="$module/.cache/openssl-$abi"
    mkdir -p "$ssl_build"
    if [[ ! -f "$prefix/lib/libcrypto.a" ]]; then
        (
            cd "$ssl_build"
            perl "$module/.cache/deps/openssl/Configure" "$ssl_target" -D__ANDROID_API__=26 \
                no-shared no-tests no-apps no-docs --prefix="$prefix" --libdir=lib
            make -j8 build_libs
            make install_dev
        ) > "$root/artifacts/android/openssl-$abi.log" 2>&1
    fi
    "$cmake" -S "$module/src/main/cpp" -B "$module/build/$abi" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$abi" -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_static \
        -DCMAKE_BUILD_TYPE=Release -DUXPLAY_SOURCE="$root/build/android-uxplay-src" \
        -DPLIST_SOURCE="$module/.cache/deps/libplist" -DCRYPTO_PREFIX="$prefix"
    "$cmake" --build "$module/build/$abi" -j8 > "$root/artifacts/android/native-$abi.log" 2>&1
    mkdir -p "$module/src/main/jniLibs/$abi"
    "$ndk/toolchains/llvm/prebuilt/$host/bin/llvm-strip" --strip-unneeded \
        -o "$module/src/main/jniLibs/$abi/libairplay_receiver.so" "$module/build/$abi/libairplay_receiver.so"
done
echo 'Native build complete; run Gradle assembleDebug to package the AAR.'
