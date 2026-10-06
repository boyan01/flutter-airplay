#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root="$1"
deps="$2"
crypto="$3"
if [[ ! -f "$crypto/lib/libcrypto.a" ]]; then
    (
        cd "$project_root/build/macos-openssl"
        perl "$deps/openssl/Configure" darwin64-arm64-cc no-shared no-tests no-apps no-docs no-module no-dso \
            --prefix="$crypto" --libdir=lib -mmacosx-version-min=12.0
        make -j8 build_libs
        make install_dev
    ) > "$project_root/artifacts/macos/openssl-build.log" 2>&1
fi
