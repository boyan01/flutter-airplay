#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo 'The iOS build currently requires an Apple Silicon Mac.' >&2; exit 1; }
python3 "$repo/android/scripts/fetch_deps.py"
deps="$repo/android/.cache/deps"
mkdir -p "$repo/artifacts/ios" "$repo/build/ios-native"
for platform in iphoneos iphonesimulator; do
    sdk="$(xcrun --sdk "$platform" --show-sdk-path)"
    triple=arm64-apple-ios15.0
    openssl_target=ios64-xcrun
    if [[ "$platform" == iphonesimulator ]]; then
        triple=arm64-apple-ios15.0-simulator
        openssl_target=iossimulator-arm64-xcrun
    fi
    crypto="$repo/build/ios-crypto-$platform"
    if [[ ! -f "$crypto/lib/libcrypto.a" ]]; then
        mkdir -p "$repo/build/ios-openssl-$platform"
        (
            cd "$repo/build/ios-openssl-$platform"
            # Explicit target triples keep device and simulator archives separate.
            CFLAGS="-target $triple -isysroot $sdk" \
            perl "$deps/openssl/Configure" "$openssl_target" no-shared no-tests no-apps no-docs no-module no-dso no-asm \
                --prefix="$crypto" --libdir=lib
            make -j8 build_libs
            make install_dev
        ) > "$repo/artifacts/ios/openssl-$platform.log" 2>&1
    fi
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
cp "$repo/native/player/player.h" "$headers/"
rm -rf "$framework"
xcodebuild -create-xcframework \
    -library "$repo/build/ios-native-iphoneos/libAirplayPlayer.a" -headers "$headers" \
    -library "$repo/build/ios-native-iphonesimulator/libAirplayPlayer.a" -headers "$headers" \
    -output "$framework"
