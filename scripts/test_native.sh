#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<'HELP'
Usage: ./scripts/test_native.sh [target] [suite] [arguments]

Without a target, run the current OS's basic native suite.
  macos [player|all|host|texture|rtp|window]
      player is the default; all adds host, texture and RTP.
      window requires a GUI session.
      player accepts CTest arguments, e.g. macos player -R playback.
  linux [player|video|host|all] [CMake arguments]
      player is the default; all includes available GTK/window tests.
      linux window [bundle-path] tests real caption dragging.
  windows [player|video|all] [CTest arguments]
      player is the default; video checks platform and FFmpeg decoders.
      Run existing fixtures prepared by build_native.ps1 -Tests.
      Invoke this script with Bash from the configured Windows toolchain.
  android [host|rtp|player [--full]|kotlin]
      host is the default; RTP is separate to avoid duplicate host runs.
      player tests selected decoders; --full restores the decoder/size matrix.
      player requires an authorized arm64 device.
  ios
      XCTest on an existing iPad simulator (IOS_TEST_DESTINATION optional).
  alac
      Standalone decoder (ALAC_SANITIZE=ON optional).
  ffmpeg
      Shared video adapter (FFMPEG_SANITIZE=ON optional).
  build
      Native preparation cache, invalidation and failed-build recovery.

Reuse current native output; see DEVELOPMENT.md for prerequisites.
HELP
}

fail() { printf '%s\n' "$*" >&2; exit 1; }

require_macos_player() {
    [[ -f "$project_root/build/macos-native/libairplay_player.dylib" ]] ||
        fail 'Run ./scripts/build_receiver.sh first.'
}

macos_player() {
    require_macos_player
    ctest --test-dir "$project_root/build/macos-native" --output-on-failure --no-tests=error "$@"
}

macos_host() (
    require_macos_player
    mkdir -p "$project_root/build/native-tests"
    swiftc -import-objc-header "$project_root/macos/Runner/Receiver-Bridging-Header.h" \
        -L "$project_root/build/macos-native" -lairplay_player \
        -Xlinker -rpath -Xlinker "$project_root/build/macos-native" \
        "$project_root/macos/Runner/ReceiverHost.swift" "$project_root/native/tests/main.swift" \
        -o "$project_root/build/native-tests/receiver-tests"
    "$project_root/build/native-tests/receiver-tests"
)

macos_texture() (
    require_macos_player
    test_root="$project_root/build/texture-tests"
    mkdir -p "$test_root"
    swiftc -emit-library -emit-module -module-name FlutterMacOS \
        "$project_root/native/texture-tests/FlutterMacOS.swift" -o "$test_root/libFlutterMacOS.dylib"
    swiftc -import-objc-header "$project_root/macos/Runner/Receiver-Bridging-Header.h" \
        -I "$test_root" -L "$test_root" -lFlutterMacOS \
        -L "$project_root/build/macos-native" -lairplay_player \
        -Xlinker -rpath -Xlinker "$test_root" -Xlinker -rpath -Xlinker "$project_root/build/macos-native" \
        "$project_root/macos/Runner/ReceiverHost.swift" "$project_root/macos/Runner/FrameTexture.swift" \
        "$project_root/native/texture-tests/main.swift" -o "$test_root/texture-tests"
    "$test_root/texture-tests"
)

macos_rtp() (
    require_macos_player
    mkdir -p "$project_root/build/rtp-tests"
    clang -I "$project_root/vendor/UxPlay/lib" -I "$project_root/build/macos-crypto/include" \
        -I "$project_root/android/.cache/deps/libplist/include" -DPLIST_210 -DPLIST_230 \
        "$project_root/native/rtp-tests/main.c" "$project_root/build/macos-native/libreceiver_core.a" \
        "$project_root/build/macos-native/libplayfair.a" "$project_root/build/macos-native/libllhttp.a" \
        "$project_root/build/macos-native/libplist.a" "$project_root/build/macos-crypto/lib/libcrypto.a" \
        -lpthread -o "$project_root/build/rtp-tests/rtp-tests"
    "$project_root/build/rtp-tests/rtp-tests"
)

macos_window() (
    test_root="$project_root/build/window-tests"
    framework_root="$project_root/build/macos/Build/Products/Debug"
    if [[ ! -d "$framework_root/FlutterMacOS.framework/Headers" ]]; then
      echo 'Generate macOS Debug output with flutter run -d macos first. See DEVELOPMENT.md for GUI test prerequisites.' >&2
      exit 1
    fi
    mkdir -p "$test_root"
    # Same-file extensions access private test seams without rewriting production code.
    cat "$project_root/macos/Runner/MainFlutterWindow.swift" "$project_root/native/window-tests/main.swift" > "$test_root/main.swift"
    swiftc -F "$framework_root" -framework FlutterMacOS \
      -Xlinker -rpath -Xlinker "$framework_root" "$test_root/main.swift" -o "$test_root/window-tests"
    # Requires a logged-in macOS GUI session. AppKit performs real fullscreen transitions.
    "$test_root/window-tests"
)

alac_tests() (
    output="$project_root/build/alac-tests"
    mkdir -p "$output"
    flags=(-g -O1 -fwrapv -fno-strict-aliasing -DTARGET_RT_LITTLE_ENDIAN=1 -I "$project_root/vendor/alac")
    if [[ "${ALAC_SANITIZE:-OFF}" == ON ]]; then flags+=(-fsanitize=address -fno-omit-frame-pointer); fi
    for source in ALACBitUtilities EndianPortable ag_dec dp_dec matrix_dec; do
        clang "${flags[@]}" -c "$project_root/vendor/alac/$source.c" -o "$output/$source.o"
    done
    clang++ -std=c++17 "${flags[@]}" -c "$project_root/vendor/alac/ALACDecoder.cpp" -o "$output/ALACDecoder.o"
    clang++ -std=c++17 "${flags[@]}" -I "$project_root/native/player" -I "$project_root/native/player-tests" \
        "$project_root/native/player-tests/alac_test.cpp" "$output/"*.o -o "$output/alac-tests"
    "$output/alac-tests"
)

ffmpeg_tests() (
    output="$project_root/build/ffmpeg-video-tests"
    mkdir -p "$output"
    pkg-config --exists libavcodec libavutil libswscale || {
        echo 'Install FFmpeg 6+ development libraries and pkg-config first.' >&2; exit 1;
    }
    flags=(-std=c++17)
    if [[ ${FFMPEG_SANITIZE:-OFF} == ON ]]; then
        flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer -g)
    fi
    "$project_root/linux/tests/generate_video_fixtures.sh" "$output/fixtures"
    "${CXX:-c++}" "${flags[@]}" -I "$project_root/native/player" -I "$project_root/native/player-tests" \
        $(pkg-config --cflags libavcodec libavutil libswscale) \
        "$project_root/native/player/linux_video.cpp" "$project_root/native/player/ffmpeg_video.cpp" \
        "$project_root/linux/tests/video_test.cpp" $(pkg-config --libs libavcodec libavutil libswscale) \
        -o "$output/video-tests"
    "$output/video-tests" "$output/fixtures"
)

android_host() (
    python3 "$project_root/android/scripts/fetch_deps.py"
    mkdir -p "$project_root/artifacts/android"
    cmake -S "$project_root/android/tests" -B "$project_root/build/android-core-host" -DCMAKE_BUILD_TYPE=Debug \
        -DHOST_SANITIZE="${HOST_SANITIZE:-OFF}" \
        -DUXPLAY_SOURCE="$project_root/vendor/UxPlay" \
        -DPLIST_SOURCE="$project_root/android/.cache/deps/libplist" -DCRYPTO_PREFIX="${HOST_CRYPTO_PREFIX:-}"
    if [[ "${1:-host}" == rtp ]]; then
        cmake --build "$project_root/build/android-core-host" --target rtp_test -j8 > "$project_root/artifacts/android/native-host.log" 2>&1 || {
            cat "$project_root/artifacts/android/native-host.log" >&2; exit 1;
        }
        "$project_root/build/android-core-host/rtp_test" | tee "$project_root/artifacts/android/rtp-test.log"
    else
        cmake --build "$project_root/build/android-core-host" --target receiver_test -j8 > "$project_root/artifacts/android/native-host.log" 2>&1 || {
            cat "$project_root/artifacts/android/native-host.log" >&2; exit 1;
        }
        "$project_root/build/android-core-host/receiver_test" | tee "$project_root/artifacts/android/core-test.log"
    fi
)

android_player() (
    case "$(uname -s)" in
        Darwin) ndk_host=darwin-x86_64; default_sdk="$HOME/Library/Android/sdk" ;;
        Linux)
            [[ "$(uname -m)" == x86_64 ]] || fail 'The Linux NDK host tools require x86_64.'
            ndk_host=linux-x86_64; default_sdk="$HOME/Android/Sdk"
            ;;
        *) fail 'Build Android fixtures on macOS or Linux x86_64.' ;;
    esac
    sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$default_sdk}}
    ndk_version=$(sed -n 's/^airplay\.ndkVersion=//p' "$project_root/android/gradle.properties")
    [[ "$ndk_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Set airplay.ndkVersion in android/gradle.properties.'
    ndk="$sdk/ndk/$ndk_version"
    toolchain="$ndk/toolchains/llvm/prebuilt/$ndk_host/bin"
    tools="$sdk/build-tools/36.0.0"
    output="$project_root/build/android-player-tests"
    mkdir -p "$output/classes" "$output/lib/arm64-v8a" "$project_root/artifacts/android"
    "$toolchain/clang++" --target=aarch64-linux-android26 \
        -std=c++17 -shared -fPIC -static-libstdc++ -Wl,-z,max-page-size=16384 \
        -I "$project_root/native/player" -I "$project_root/native/player-tests" \
        -I "$project_root/vendor/UxPlay/lib" \
        -I "$project_root/android/.cache/deps/oboe/include" \
        "$project_root/native/player-tests/android/player_test.cpp" \
        "$project_root/native/player-tests/session_test.cpp" \
        -L "$project_root/android/app/src/main/jniLibs/arm64-v8a" -lairplay_player -landroid -lmediandk -llog \
        -o "$output/lib/arm64-v8a/libplayer_regression.so"
    cp "$project_root/android/app/src/main/jniLibs/arm64-v8a/libairplay_player.so" "$output/lib/arm64-v8a/"
    javac -source 17 -target 17 -cp "$sdk/platforms/android-36/android.jar" \
        -d "$output/classes" "$project_root/native/player-tests/android/"*.java \
        "$project_root/native/player/android/tech/soit/flutterairplay/audio/"*.java
    "$tools/d8" --min-api 26 --output "$output" "$output/classes/tech/soit/flutterairplay/player_regression/"*.class \
        "$output/classes/tech/soit/flutterairplay/audio/"*.class
    cat > "$output/AndroidManifest.xml" <<'MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="tech.soit.flutterairplay.player_regression">
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
    if [[ ${AIRPLAY_AUDIO_ONLY:-0} == 1 || "${1:-}" == --full ]]; then
        launch_args=(--ez fullMatrix false)
        if [[ "${1:-}" == --full ]]; then launch_args=(--ez fullMatrix true); fi
        if [[ ${AIRPLAY_AUDIO_ONLY:-0} == 1 ]]; then launch_args+=(--ez audioOnly true); fi
        android install --apks="$output/player-tests.apk"
        "$sdk/platform-tools/adb" shell am start -S -n tech.soit.flutterairplay.player_regression/.TestActivity "${launch_args[@]}"
    else
        android run --apks="$output/player-tests.apk"
    fi
    # Poll only this fixture's log tag; the timeout is bounded and output is local.
    for attempt in {1..120}; do
        "$sdk/platform-tools/adb" logcat -d -T "$started" -s PlayerRegression:I '*:S' > "$project_root/artifacts/android/player-device-tests.log"
        if rg -q 'COMPLETE: (PASS:|FAIL:)' "$project_root/artifacts/android/player-device-tests.log"; then break; fi
        sleep 1
    done
    cat "$project_root/artifacts/android/player-device-tests.log"
    rg -q 'COMPLETE: PASS:' "$project_root/artifacts/android/player-device-tests.log"
)

ios_tests() (
    [[ -d "$project_root/build/ios-native/AirplayPlayer.xcframework" ]] || {
        echo 'Run ./ios/scripts/build_native.sh first. See DEVELOPMENT.md for iPad test prerequisites.' >&2; exit 1;
    }
    destination=${IOS_TEST_DESTINATION:-}
    if [[ -z "$destination" ]]; then
        device=$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
groups=json.load(sys.stdin)["devices"]
for runtime in sorted(groups, key=lambda key: tuple(map(int,re.findall(r"\d+",key))), reverse=True):
    for device in groups[runtime]:
        if device["name"].startswith("iPad") and device.get("isAvailable"):
            print(device["udid"]); sys.exit(0)
sys.exit("No installed iPad simulator is available")')
        destination="id=$device"
    fi
    mkdir -p "$project_root/artifacts/ios"
    result="$project_root/artifacts/ios/player-tests.xcresult"
    [[ ! -e "$result" ]] || result="$project_root/artifacts/ios/player-tests-$(date +%Y%m%d-%H%M%S).xcresult"
    cd "$project_root"
    xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
        -sdk iphonesimulator -destination "$destination" -derivedDataPath "$project_root/build/ios-tests" \
        -resultBundlePath "$result" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
)

linux_tests() (
    suite=player
    if [[ $# -gt 0 && "$1" != -* ]]; then suite="$1"; shift; fi
    targets=()
    test_args=(--no-tests=error)
    case "$suite" in
        player)
            targets=(linux_player_tests linux_session_tests linux_audio_decoder_tests linux_audio_output_tests)
            test_args+=(-R '^linux_(playback|sender_resume|audio_decode_recovery|audio_unavailable_cleanup)$')
            ;;
        video) targets=(linux_video_tests); test_args+=(-R '^linux_video_reorder_recovery$') ;;
        host) targets=(linux_host_tests); test_args+=(-R '^linux_flutter_host_lifecycle$') ;;
        all) ;;
        *) fail "Unknown Linux suite: $suite. Use --help." ;;
    esac
    cmake -S "$project_root/linux/tests" -B "$project_root/build/linux-native" -G Ninja -DCMAKE_BUILD_TYPE=Debug "$@"
    if [[ "$suite" != all ]]; then
        cmake --build "$project_root/build/linux-native" --parallel --target "${targets[@]}"
    else
        cmake --build "$project_root/build/linux-native" --parallel
    fi
    ctest --test-dir "$project_root/build/linux-native" --output-on-failure "${test_args[@]}"
)

linux_window() (
    if [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]]; then
      echo 'SKIP: real Flutter caption drag is unsupported in the hosted Xvfb environment (GDK event device errors). GTK/window lifecycle tests still run.'
      exit 0
    fi
    for command in xvfb-run dbus-run-session openbox xdotool python3; do
      command -v "$command" >/dev/null || { echo "Missing window test dependency: $command" >&2; exit 1; }
    done
    bundle="${1:-$project_root/build/linux/x64/debug/bundle}"
    xvfb-run -a dbus-run-session -- python3 "$project_root/linux/tests/window_drag_test.py" "$bundle/flutter_airplay"
)

macos_tests() {
    local suite="${1:-player}"
    if [[ $# -gt 0 ]]; then shift; fi
    if [[ "$suite" != player && $# -gt 0 ]]; then fail 'Only the player suite accepts CTest arguments.'; fi
    case "$suite" in
        all) macos_player; macos_host; macos_texture; macos_rtp ;;
        player) macos_player "$@" ;;
        host) macos_host ;;
        texture) macos_texture ;;
        rtp) macos_rtp ;;
        window) macos_window ;;
        *) fail "Unknown macOS suite: $suite. Use --help." ;;
    esac
}

android_tests() {
    local suite="${1:-host}"
    if [[ $# -gt 0 ]]; then shift; fi
    if [[ "$suite" == player ]]; then
        [[ $# -eq 0 || ( $# -eq 1 && "$1" == --full ) ]] || fail 'Android player accepts only --full.'
    else
        [[ $# -eq 0 ]] || fail 'Only Android player accepts --full.'
    fi
    case "$suite" in
        host) android_host ;;
        rtp) android_host rtp ;;
        player) android_player "$@" ;;
        kotlin)
            : "${GRADLE_BIN:?Set GRADLE_BIN to the configured Gradle executable}"
            "$GRADLE_BIN" -p "$project_root/android" :app:testDebugUnitTest -Ptarget-platform=android-arm64
            ;;
        *) fail "Unknown Android suite: $suite. Use --help." ;;
    esac
}

windows_tests() {
    local suite=player
    if [[ $# -gt 0 && "$1" != -* ]]; then suite="$1"; shift; fi
    local test_args=(--no-tests=error)
    case "$suite" in
        player) test_args+=(-R '^windows_(pixels|compat|httpd|audio_clock|audio_decode_recovery)$') ;;
        video) test_args+=(-R '^windows_(video|hevc_software)$') ;;
        all) ;;
        *) fail "Unknown Windows suite: $suite. Use --help." ;;
    esac
    [[ -f "$project_root/build/windows-native/CTestTestfile.cmake" ]] ||
        fail 'Build Windows fixtures with windows/scripts/build_native.ps1 -Tests first.'
    ctest --test-dir "$project_root/build/windows-native" -C Release --output-on-failure "${test_args[@]}" "$@"
}

if [[ $# -eq 0 ]]; then
    case "$(uname -s)" in
        Darwin) target=macos ;;
        Linux) target=linux ;;
        MINGW*|MSYS*|CYGWIN*) target=windows ;;
        *) fail 'Unknown host OS. Select a target explicitly; use --help.' ;;
    esac
else
    target="$1"
    shift
fi

case "$target" in
    --help|-h) usage ;;
    build)
        [[ $# -eq 0 ]] || fail 'build does not accept extra arguments.'
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*) python "$project_root/scripts/tests/test_native_preparation.py" ;;
            *) python3 "$project_root/scripts/tests/test_native_preparation.py" ;;
        esac
        ;;
    macos) macos_tests "$@" ;;
    linux)
        if [[ "${1:-}" == window ]]; then
            shift
            [[ $# -le 1 ]] || fail 'Linux window accepts one optional bundle path.'
            linux_window "$@"
        else
            linux_tests "$@"
        fi
        ;;
    windows) windows_tests "$@" ;;
    android) android_tests "$@" ;;
    ios|alac|ffmpeg)
        [[ $# -eq 0 ]] || fail "$target does not accept extra arguments. Use --help."
        case "$target" in
            ios) ios_tests ;;
            alac) alac_tests ;;
            ffmpeg) ffmpeg_tests ;;
        esac
        ;;
    *) fail "Unknown target: $target. Use --help." ;;
esac
