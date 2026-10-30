#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo 'The iOS build currently requires an Apple Silicon Mac.' >&2; exit 1; }
: "${BUILT_PRODUCTS_DIR:?Build through Xcode or flutter build ios: the player uses its lychee.framework}"
for platform in iphoneos iphonesimulator; do
    output="$repo/build/ios-native-$platform"
    # The static player needs only lychee's headers, the same in every slice;
    # the app links lychee.framework through the plugin.
    cmake -S "$repo/native/apple" -B "$output" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$platform" --show-sdk-path)" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DAIRPLAY_DNS_STUB=ON \
        -DAIRPLAY_LYCHEE_FRAMEWORK="$BUILT_PRODUCTS_DIR/lychee.framework"
    cmake --build "$output" --target airplay_player_archive --parallel 8
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
