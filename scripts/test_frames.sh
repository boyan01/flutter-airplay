#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$project_root/build/texture-tests"
mkdir -p "$test_root"
swiftc -emit-library -emit-module -module-name FlutterMacOS \
    "$project_root/native/texture-tests/FlutterMacOS.swift" -o "$test_root/libFlutterMacOS.dylib"
swiftc -import-objc-header "$project_root/macos/Runner/Receiver-Bridging-Header.h" \
    -I "$test_root" -L "$test_root" -lFlutterMacOS \
    -L "$project_root/build/macos-native" -lairplay_player \
    -Xlinker -rpath -Xlinker "$test_root" -Xlinker -rpath -Xlinker "$project_root/build/macos-native" \
    "$project_root/macos/Runner/ReceiverHost.swift" "$project_root/macos/Runner/FrameTexture.swift" \
    "$project_root/native/texture-tests/main.swift" -o "$test_root/texture-tests"
"$test_root/texture-tests"
