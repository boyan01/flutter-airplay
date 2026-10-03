#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/build/native-tests"
swiftc -import-objc-header "$project_root/macos/Runner/Receiver-Bridging-Header.h" \
    -L "$project_root/build/macos-native" -lairplay_player \
    -Xlinker -rpath -Xlinker "$project_root/build/macos-native" \
    "$project_root/macos/Runner/ReceiverHost.swift" "$project_root/native/tests/main.swift" \
    -o "$project_root/build/native-tests/receiver-tests"
"$project_root/build/native-tests/receiver-tests"
