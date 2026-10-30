#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo 'The distributable macOS build currently targets Apple Silicon.' >&2; exit 1; }
command -v cmake >/dev/null || { echo 'Install CMake before building the native player.' >&2; exit 1; }
: "${BUILT_PRODUCTS_DIR:?Build through Xcode or flutter build macos: the player links its lychee.framework}"
cmake -S "$project_root/native/apple" -B "$project_root/build/macos-native" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DAIRPLAY_BUILD_TESTS=OFF -DAIRPLAY_LYCHEE_FRAMEWORK="$BUILT_PRODUCTS_DIR/lychee.framework"
cmake --build "$project_root/build/macos-native" --target airplay_player --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
