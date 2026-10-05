#!/bin/bash
set -euo pipefail
app=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$app/.." && pwd)
case "$(uname -s)" in
    Darwin) ndk_host=darwin-x86_64; default_sdk="$HOME/Library/Android/sdk" ;;
    Linux)
        [[ "$(uname -m)" == x86_64 ]] || { echo 'The Linux NDK host tools require x86_64.' >&2; exit 1; }
        ndk_host=linux-x86_64; default_sdk="$HOME/Android/Sdk"
        ;;
    *) echo 'Build Android native code on macOS or Linux x86_64.' >&2; exit 1 ;;
esac
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$default_sdk}}
ndk_version=$(sed -n 's/^airplay\.ndkVersion=//p' "$app/gradle.properties")
[[ "$ndk_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Set airplay.ndkVersion in android/gradle.properties.' >&2; exit 1; }
ndk="$sdk/ndk/$ndk_version"
toolchain="$ndk/toolchains/llvm/prebuilt/$ndk_host/bin"
cmake="$sdk/cmake/3.22.1/bin/cmake"
[[ -x "$toolchain/clang" && -x "$cmake" ]] || { echo 'Install the project NDK and CMake 3.22.1 with sdkmanager first.' >&2; exit 1; }
python3 "$repo/scripts/ensure_native.py" android --prepare-dependencies
python3 "$app/scripts/fetch_deps.py"
export ANDROID_NDK_ROOT="$ndk"
export PATH="$toolchain:$PATH"
prefix="$app/.cache/crypto-arm64-v8a-$ndk_version"
if [[ ! -f "$prefix/lib/libcrypto.a" ]]; then
    mkdir -p "$app/.cache/openssl-arm64-v8a-$ndk_version" "$repo/artifacts/android"
    (
        cd "$app/.cache/openssl-arm64-v8a-$ndk_version"
        perl "$app/.cache/deps/openssl/Configure" android-arm64 -D__ANDROID_API__=26 \
            no-shared no-tests no-apps no-docs --prefix="$prefix" --libdir=lib
        make -j8 build_libs
        make install_dev
    ) > "$repo/artifacts/android/openssl-arm64-v8a.log" 2>&1
fi
output="$repo/build/android-native-arm64-$ndk_version"
"$cmake" -S "$app/app/src/main/cpp" -B "$output" -G Ninja \
 -DCMAKE_MAKE_PROGRAM="$sdk/cmake/3.22.1/bin/ninja" \
 -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
 -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DCMAKE_BUILD_TYPE=Release \
 -DUXPLAY_SOURCE="$repo/vendor/UxPlay" \
 -DPLIST_SOURCE="$app/.cache/deps/libplist" \
 -DCRYPTO_PREFIX="$prefix" \
 -DDEPS_SOURCE="$app/.cache/deps"
"$cmake" --build "$output" --parallel 8
mkdir -p "$app/app/src/main/jniLibs/arm64-v8a"
cp "$output/libairplay_player.so" "$app/app/src/main/jniLibs/arm64-v8a/"
"$toolchain/llvm-strip" "$app/app/src/main/jniLibs/arm64-v8a/libairplay_player.so"
