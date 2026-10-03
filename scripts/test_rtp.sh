#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/build/rtp-tests"
read -r -a crypto_cflags <<< "$(pkg-config --cflags openssl)"
clang -I "$project_root/vendor/UxPlay/lib" "${crypto_cflags[@]}" "$project_root/native/rtp-tests/main.c" "$project_root/build/uxplay-native/lib/libairplay.a" "$project_root/build/uxplay-native/lib/playfair/libplayfair.a" "$project_root/build/uxplay-native/lib/llhttp/libllhttp.a" /opt/homebrew/lib/libplist-2.0.a /opt/homebrew/lib/libcrypto.a -lpthread -o "$project_root/build/rtp-tests/rtp-tests"
"$project_root/build/rtp-tests/rtp-tests"
