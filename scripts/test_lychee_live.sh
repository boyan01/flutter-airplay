#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Production callback smoke test, reusing the app build's native configuration
# (flutter build macos / flutter build apk --debug first).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-macos}"
output="$root/build/lychee-live-tests-$target"
mkdir -p "$output"
python3 "$root/native/tests/playback/generate_eld_packets.py" "$output/eld.packets"
if [[ "$target" == macos ]]; then
    [[ -f "$root/build/macos-native/CMakeCache.txt" ]] || { echo 'Run flutter build macos first.' >&2; exit 1; }
    cmake -S "$root/native/apple" -B "$root/build/macos-native" -DAIRPLAY_LYCHEE_TESTS=ON
    cmake --build "$root/build/macos-native" --target lychee_live_tests --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
    # The lychee_player plugin's framework the app build linked.
    framework="$(sed -n 's/^AIRPLAY_LYCHEE_FRAMEWORK:PATH=//p' "$root/build/macos-native/CMakeCache.txt")"
    DYLD_FRAMEWORK_PATH="$(dirname "$framework")" "$root/build/macos-native/native/lychee_live_tests" "$output/eld.packets"
elif [[ "$target" == android ]]; then
    sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    tools="$sdk/build-tools/36.0.0"
    # The pixel check is lychee_player's tool, from its repository.
    : "${AIRPLAY_LYCHEE_ROOT:?Set AIRPLAY_LYCHEE_ROOT to a lychee_player checkout for tool/frame_check.py}"
    apk="$root/build/app/outputs/flutter-apk/app-debug.apk"
    native="$(ls -td "$root"/android/app/.cxx/Debug/*/arm64-v8a 2>/dev/null | head -1)"
    [[ -f "$apk" && -n "$native" ]] || { echo 'Run flutter build apk --debug first.' >&2; exit 1; }
    cmake_android="$sdk/cmake/3.22.1/bin/cmake"
    "$cmake_android" -S "$root/android/app/src/main/cpp" -B "$native" -DAIRPLAY_LYCHEE_TESTS=ON
    "$cmake_android" --build "$native" --target lychee_live_tests --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
    rm -rf "$output/lib"
    mkdir -p "$output/classes" "$output/lib/arm64-v8a" "$output/assets"
    cp "$output/eld.packets" "$output/assets/"
    # The player, lychee and its STL as the app ships them.
    unzip -joq "$apk" 'lib/arm64-v8a/libairplay_player.so' 'lib/arm64-v8a/liblychee.so' \
        'lib/arm64-v8a/libc++_shared.so' -d "$output/lib/arm64-v8a"
    cp "$(sed -n 's/^CMAKE_LIBRARY_OUTPUT_DIRECTORY:[A-Z]*=//p' "$native/CMakeCache.txt")/liblychee_live_tests.so" "$output/lib/arm64-v8a/"
    javac -source 17 -target 17 -cp "$sdk/platforms/android-37.0/android.jar" \
        -d "$output/classes" "$root/android/tests/live/TestActivity.java"
    "$tools/d8" --min-api 26 --output "$output" "$output/classes/tech/soit/flutterairplay/live_regression/"*.class
    cat > "$output/AndroidManifest.xml" <<'MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="tech.soit.flutterairplay.live_regression">
    <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="36" />
    <application android:label="Lychee live callback test" android:extractNativeLibs="true">
        <activity android:name=".TestActivity" android:exported="true">
            <intent-filter><action android:name="android.intent.action.MAIN" /><category android:name="android.intent.category.LAUNCHER" /></intent-filter>
        </activity>
    </application>
</manifest>
MANIFEST
    "$tools/aapt2" link -I "$sdk/platforms/android-37.0/android.jar" --manifest "$output/AndroidManifest.xml" -o "$output/unsigned.apk"
    (cd "$output" && zip -q unsigned.apk classes.dex assets/eld.packets lib/arm64-v8a/*.so)
    "$tools/zipalign" -f -p 4 "$output/unsigned.apk" "$output/aligned.apk"
    if [[ ! -f "$output/test.keystore" ]]; then
        keytool -genkeypair -keystore "$output/test.keystore" -storepass android -keypass android \
            -alias test -dname 'CN=Lychee live fixtures' -keyalg RSA -validity 3650 > /dev/null 2>&1
    fi
    "$tools/apksigner" sign --ks "$output/test.keystore" --ks-pass pass:android --out "$output/live-tests.apk" "$output/aligned.apk"
    device="${ANDROID_SERIAL:-emulator-5554}"
    started="$(adb -s "$device" shell "date '+%m-%d %H:%M:%S.000'")"
    android run --device="$device" --apks="$output/live-tests.apk" \
        --activity=tech.soit.flutterairplay.live_regression.TestActivity
    for ((attempt=0; attempt<100; ++attempt)); do
        result="$(adb -s "$device" logcat -d -T "$started" -s LycheeLiveTest:I AndroidRuntime:E '*:S')"
        if grep -Eq 'FAIL:|FATAL EXCEPTION' <<<"$result"; then printf '%s\n' "$result"; exit 1; fi
        if grep -q 'PASS: production callbacks' <<<"$result"; then
            printf '%s\n' "$result"
            for name in red paused blue; do
                adb -s "$device" pull "/sdcard/Android/data/tech.soit.flutterairplay.live_regression/files/$name.png" "$output/$name.png"
                ffmpeg -v error -y -i "$output/$name.png" "$output/$name.ppm"
                color=red; [[ "$name" != blue ]] || color=blue
                ffmpeg -v error -y -f lavfi -i "color=$color:size=640x360" -frames:v 1 -c:v libx264 "$output/$color.mp4"
                python3 -I "$AIRPLAY_LYCHEE_ROOT/tool/frame_check.py" "$output/$color.mp4" "$output/$name.ppm" --pts 0
            done
            exit 0
        fi
        sleep 0.2
    done
    printf '%s\n' "$result"; echo 'Timed out waiting for live callback test' >&2; exit 1
else
    echo 'usage: test_lychee_live.sh [macos|android]' >&2; exit 1
fi
