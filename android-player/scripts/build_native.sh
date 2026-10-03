#!/bin/bash
set -euo pipefail
app=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$app/.." && pwd)
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
ndk="$sdk/ndk/28.2.13676358"
cmake="$sdk/cmake/3.22.1/bin/cmake"
python3 "$repo/android-prototype/scripts/prepare_core.py"
"$cmake" -S "$app/android/app/src/main/cpp" -B "$app/build/native-arm64" -G Ninja \
 -DCMAKE_MAKE_PROGRAM="$sdk/cmake/3.22.1/bin/ninja" \
 -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
 -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DCMAKE_BUILD_TYPE=Release \
 -DUXPLAY_SOURCE="$repo/build/android-uxplay-src" \
 -DPLIST_SOURCE="$repo/android-prototype/.cache/deps/libplist" \
 -DCRYPTO_PREFIX="$repo/android-prototype/.cache/crypto-arm64-v8a" \
 -DFOUNDATION_SOURCE="$repo/android-prototype/src/main/cpp" \
 -DDEPS_SOURCE="$repo/android-prototype/.cache/deps"
"$cmake" --build "$app/build/native-arm64" --parallel 8
mkdir -p "$app/android/app/src/main/jniLibs/arm64-v8a"
cp "$app/build/native-arm64/libairplay_player.so" "$app/android/app/src/main/jniLibs/arm64-v8a/"
"$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip" "$app/android/app/src/main/jniLibs/arm64-v8a/libairplay_player.so"
