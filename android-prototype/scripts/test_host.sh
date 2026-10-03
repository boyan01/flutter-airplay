#!/usr/bin/env bash
set -euo pipefail
module="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$module/.." && pwd)"
: "${JAVA_HOME:?Set JAVA_HOME to a JDK}"
: "${HOST_CRYPTO_PREFIX:?Set HOST_CRYPTO_PREFIX to native OpenSSL installation}"
python3 "$module/scripts/prepare_core.py"
mkdir -p "$root/artifacts/android" "$module/build/java-tests"
cmake -S "$module/src/main/cpp" -B "$module/build/host" -DCMAKE_BUILD_TYPE=Debug \
    -DUXPLAY_SOURCE="$root/build/android-uxplay-src" \
    -DPLIST_SOURCE="$module/.cache/deps/libplist" -DCRYPTO_PREFIX="$HOST_CRYPTO_PREFIX"
cmake --build "$module/build/host" -j8 > "$root/artifacts/android/native-host.log" 2>&1
"$module/build/host/receiver_test" | tee "$root/artifacts/android/core-test.log"
"$JAVA_HOME/bin/javac" -d "$module/build/java-tests" \
    "$module/src/main/java/io/github/boyan01/airplay/TxtRecords.java" "$module/tests/TxtRecordsTest.java"
"$JAVA_HOME/bin/java" -cp "$module/build/java-tests" io.github.boyan01.airplay.TxtRecordsTest \
    | tee "$root/artifacts/android/txt-test.log"
