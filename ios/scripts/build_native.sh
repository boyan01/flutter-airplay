#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo 'The iOS build currently requires an Apple Silicon Mac.' >&2; exit 1; }
python3 "$repo/scripts/ensure_native.py" ios --prepare-dependencies
python3 "$repo/scripts/fetch_native_deps.py"
deps="$repo/build/native-deps"
mkdir -p "$repo/artifacts/ios" "$repo/build/ios-native"
for platform in iphoneos iphonesimulator; do
    sdk="$(xcrun --sdk "$platform" --show-sdk-path)"
    crypto="$repo/build/ios-crypto-$platform"
    bash "$repo/ios/scripts/build_crypto.sh" "$repo" "$deps" "$platform" "$sdk" "$crypto"
    output="$repo/build/ios-native-$platform"
    cmake -S "$repo/native" -B "$output" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
        -DUXPLAY_SOURCE="$repo/vendor/UxPlay" -DPLIST_SOURCE="$deps/libplist" \
        -DCRYPTO_PREFIX="$crypto" -DDEPS_SOURCE="$deps" -DAIRPLAY_DNS_STUB=ON
    cmake --build "$output" --parallel 8
    libtool -static -o "$output/libAirplayPlayer.a" "$output/libairplay_player.a" \
        "$output/libreceiver_core.a" "$output/libplist.a" "$output/libllhttp.a" \
        "$output/libplayfair.a" "$crypto/lib/libcrypto.a"
done
framework="$repo/build/ios-native/AirplayPlayer.xcframework"
headers="$repo/build/ios-native/headers"
mkdir -p "$headers"
cp "$repo/native/include/airplay/player.h" "$repo/native/include/airplay/receiver.h" "$repo/native/include/airplay/receiver_ffi.h" "$headers/"
rm -rf "$framework"
xcodebuild -create-xcframework \
    -library "$repo/build/ios-native-iphoneos/libAirplayPlayer.a" -headers "$headers" \
    -library "$repo/build/ios-native-iphonesimulator/libAirplayPlayer.a" -headers "$headers" \
    -output "$framework"
