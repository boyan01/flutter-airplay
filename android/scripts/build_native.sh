#!/bin/bash
set -euo pipefail
app=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$app/.." && pwd)
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
ndk="$sdk/ndk/28.2.13676358"
cmake="$sdk/cmake/3.22.1/bin/cmake"
python3 "$app/scripts/fetch_deps.py"
export ANDROID_NDK_ROOT="$ndk"
export PATH="$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin:$PATH"
prefix="$app/.cache/crypto-arm64-v8a"
if [[ ! -f "$prefix/lib/libcrypto.a" ]]; then
    mkdir -p "$app/.cache/openssl-arm64-v8a" "$repo/artifacts/android"
    (
        cd "$app/.cache/openssl-arm64-v8a"
        perl "$app/.cache/deps/openssl/Configure" android-arm64 -D__ANDROID_API__=26 \
            no-shared no-tests no-apps no-docs --prefix="$prefix" --libdir=lib
        make -j8 build_libs
        make install_dev
    ) > "$repo/artifacts/android/openssl-arm64-v8a.log" 2>&1
fi
"$cmake" -S "$app/app/src/main/cpp" -B "$repo/build/android-native-arm64" -G Ninja \
 -DCMAKE_MAKE_PROGRAM="$sdk/cmake/3.22.1/bin/ninja" \
 -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
 -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DCMAKE_BUILD_TYPE=Release \
 -DUXPLAY_SOURCE="$repo/vendor/UxPlay" \
 -DPLIST_SOURCE="$app/.cache/deps/libplist" \
 -DCRYPTO_PREFIX="$app/.cache/crypto-arm64-v8a" \
 -DDEPS_SOURCE="$app/.cache/deps"
"$cmake" --build "$repo/build/android-native-arm64" --parallel 8
mkdir -p "$app/app/src/main/jniLibs/arm64-v8a"
cp "$repo/build/android-native-arm64/libairplay_player.so" "$app/app/src/main/jniLibs/arm64-v8a/"
"$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip" "$app/app/src/main/jniLibs/arm64-v8a/libairplay_player.so"
