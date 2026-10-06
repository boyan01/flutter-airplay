#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
repo="$1"; deps="$2"; platform="$3"; sdk="$4"; crypto="$5"
triple=arm64-apple-ios15.0
openssl_target=ios64-xcrun
if [[ "$platform" == iphonesimulator ]]; then
    triple=arm64-apple-ios15.0-simulator
    openssl_target=iossimulator-arm64-xcrun
fi
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
