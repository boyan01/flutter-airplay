#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo 'The distributable macOS build currently targets Apple Silicon.' >&2; exit 1; }
command -v cmake >/dev/null || { echo 'Install CMake before building the native player.' >&2; exit 1; }
python3 "$project_root/scripts/ensure_native.py" macos --prepare-dependencies
python3 "$project_root/scripts/fetch_native_deps.py"
deps="$project_root/build/native-deps"
crypto="$project_root/build/macos-crypto"
mkdir -p "$project_root/artifacts/macos" "$project_root/build/macos-openssl"
bash "$project_root/scripts/build_macos_crypto.sh" "$project_root" "$deps" "$crypto"
cmake -S "$project_root/native" -B "$project_root/build/macos-native" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DUXPLAY_SOURCE="$project_root/vendor/UxPlay" -DPLIST_SOURCE="$deps/libplist" \
    -DCRYPTO_PREFIX="$crypto" -DDEPS_SOURCE="$deps" -DAIRPLAY_BUILD_TESTS=OFF
cmake --build "$project_root/build/macos-native" --target airplay_player --parallel 8
