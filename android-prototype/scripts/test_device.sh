#!/usr/bin/env bash
set -euo pipefail
module="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$module/.." && pwd)"
: "${ANDROID_SERIAL:?Set ANDROID_SERIAL to an explicitly selected adb target}"
apk="$module/device-harness/build/outputs/apk/debug/device-harness-debug.apk"
[[ -f "$apk" ]] || { echo 'Build :device-harness:assembleDebug first'; exit 1; }
mkdir -p "$root/artifacts/android"
android install --device="$ANDROID_SERIAL" --apks="$apk" --install-options=-r
adb -s "$ANDROID_SERIAL" shell am instrument -w \
    io.github.boyan01.airplay.validation/.CoreInstrumentation \
    | tee "$root/artifacts/android/device-core-test.log"
rg -q '^PASS: JNI load' "$root/artifacts/android/device-core-test.log"
if rg -q 'FAIL:|INSTRUMENTATION_FAILED' "$root/artifacts/android/device-core-test.log"; then exit 1; fi
