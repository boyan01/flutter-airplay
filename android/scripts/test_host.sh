#!/usr/bin/env bash
set -euo pipefail
app="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$app/.." && pwd)"
: "${HOST_CRYPTO_PREFIX:?Set HOST_CRYPTO_PREFIX to native OpenSSL installation}"
python3 "$app/scripts/fetch_deps.py"
mkdir -p "$repo/artifacts/android"
cmake -S "$app/tests" -B "$repo/build/android-core-host" -DCMAKE_BUILD_TYPE=Debug \
    -DHOST_SANITIZE="${HOST_SANITIZE:-OFF}" \
    -DUXPLAY_SOURCE="$repo/vendor/UxPlay" \
    -DPLIST_SOURCE="$app/.cache/deps/libplist" -DCRYPTO_PREFIX="$HOST_CRYPTO_PREFIX"
cmake --build "$repo/build/android-core-host" -j8 > "$repo/artifacts/android/native-host.log" 2>&1
"$repo/build/android-core-host/receiver_test" | tee "$repo/artifacts/android/core-test.log"
"$repo/build/android-core-host/rtp_test" | tee "$repo/artifacts/android/rtp-test.log"
