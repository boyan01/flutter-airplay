#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Separate synthetic fixture app; never replaces the installed receiver app.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}
ndk="$sdk/ndk/28.2.13676358"
tools="$sdk/build-tools/36.0.0"
output="$project_root/build/android-player-tests"
mkdir -p "$output/classes" "$output/lib/arm64-v8a" "$project_root/artifacts/android"
"$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang++" \
    -std=c++17 -shared -fPIC -static-libstdc++ -Wl,-z,max-page-size=16384 \
    -I "$project_root/native/player" -I "$project_root/native/player-tests" \
    -I "$project_root/vendor/UxPlay/lib" \
    "$project_root/native/player-tests/android/player_test.cpp" \
    "$project_root/native/player-tests/session_test.cpp" \
    -L "$project_root/android/app/src/main/jniLibs/arm64-v8a" -lairplay_player -landroid -lmediandk -llog \
    -o "$output/lib/arm64-v8a/libplayer_regression.so"
cp "$project_root/android/app/src/main/jniLibs/arm64-v8a/libairplay_player.so" "$output/lib/arm64-v8a/"
javac -source 17 -target 17 -cp "$sdk/platforms/android-36/android.jar" \
    -d "$output/classes" "$project_root/native/player-tests/android/"*.java
"$tools/d8" --min-api 26 --output "$output" "$output/classes/io/github/boyan01/player_regression/"*.class
cat > "$output/AndroidManifest.xml" <<'MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="io.github.boyan01.player_regression">
    <uses-sdk android:minSdkVersion="26" android:targetSdkVersion="36" />
    <application android:label="Native playback fixtures" android:extractNativeLibs="true">
        <activity android:name=".TestActivity" android:exported="true">
            <intent-filter><action android:name="android.intent.action.MAIN" /><category android:name="android.intent.category.LAUNCHER" /></intent-filter>
        </activity>
    </application>
</manifest>
MANIFEST
"$tools/aapt2" link -I "$sdk/platforms/android-36/android.jar" --manifest "$output/AndroidManifest.xml" -o "$output/unsigned.apk"
(cd "$output" && zip -q unsigned.apk classes.dex lib/arm64-v8a/*.so)
"$tools/zipalign" -f -p 4 "$output/unsigned.apk" "$output/aligned.apk"
if [[ ! -f "$output/test.keystore" ]]; then
    keytool -genkeypair -keystore "$output/test.keystore" -storepass android -keypass android \
        -alias test -dname 'CN=Native playback fixtures' -keyalg RSA -validity 3650 > /dev/null 2>&1
fi
"$tools/apksigner" sign --ks "$output/test.keystore" --ks-pass pass:android --out "$output/player-tests.apk" "$output/aligned.apk"
started=$("$sdk/platform-tools/adb" shell "date '+%m-%d %H:%M:%S.000'")
android run --apks="$output/player-tests.apk"
# Poll only this fixture's log tag; the timeout is bounded and output is local.
for attempt in {1..30}; do
    "$sdk/platform-tools/adb" logcat -d -T "$started" -s PlayerRegression:I '*:S' > "$project_root/artifacts/android/player-device-tests.log"
    if rg -q 'PASS:|FAIL:' "$project_root/artifacts/android/player-device-tests.log"; then break; fi
    sleep 1
done
cat "$project_root/artifacts/android/player-device-tests.log"
rg -q 'PASS:' "$project_root/artifacts/android/player-device-tests.log"
