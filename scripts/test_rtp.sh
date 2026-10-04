#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/build/rtp-tests"
clang -I "$project_root/vendor/UxPlay/lib" -I "$project_root/build/macos-crypto/include" \
    -I "$project_root/android/.cache/deps/libplist/include" -DPLIST_210 -DPLIST_230 \
    "$project_root/native/rtp-tests/main.c" "$project_root/build/macos-native/libreceiver_core.a" \
    "$project_root/build/macos-native/libplayfair.a" "$project_root/build/macos-native/libllhttp.a" \
    "$project_root/build/macos-native/libplist.a" "$project_root/build/macos-crypto/lib/libcrypto.a" \
    -lpthread -o "$project_root/build/rtp-tests/rtp-tests"
"$project_root/build/rtp-tests/rtp-tests"
