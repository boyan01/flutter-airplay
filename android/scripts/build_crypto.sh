#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
app="$1"
repo="$2"
prefix="$3"
ndk_version="$4"
if [[ ! -f "$prefix/lib/libcrypto.a" ]]; then
    mkdir -p "$app/.cache/openssl-arm64-v8a-$ndk_version" "$repo/artifacts/android"
    (
        cd "$app/.cache/openssl-arm64-v8a-$ndk_version"
        perl "$repo/build/native-deps/openssl/Configure" android-arm64 -D__ANDROID_API__=26 \
            no-shared no-tests no-apps no-docs --prefix="$prefix" --libdir=lib
        make -j8 build_libs
        make install_dev
    ) > "$repo/artifacts/android/openssl-arm64-v8a.log" 2>&1
fi
