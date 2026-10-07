#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<'HELP'
Usage: ./scripts/test_native.sh [target] [suite] [arguments]

Without a target, run the current OS's basic native suite.
  macos [player|all|host|texture|rtp|window|desktop]
      player is the default; all adds host, texture, RTP and GUI window tests.
      all/window require a Debug Flutter app and a logged-in GUI session.
      player accepts CTest arguments, e.g. macos player -R playback.
  linux [player|video|gpu|host|all] [--filter CTest-regex] [--verbose] [CMake arguments]
      player is the default; all includes available GTK/window tests.
      Argument-free all also runs caption drag and standalone ALAC tests.
      linux window [bundle-path] tests real caption dragging.
  windows [player|video|texture|all] [CTest arguments]
      player is the default; video checks platform and FFmpeg decoders.
      Run existing fixtures prepared by build_native.ps1 -Tests.
      Argument-free all includes texture; extra arguments select native CTest only.
      texture uses windows_texture_test built in the Flutter Windows project.
      installer <setup.exe> checks install, upgrade, startup and uninstall.
      Invoke this script with Bash from the configured Windows toolchain.
  <macos|linux|windows> desktop [--os-input]
      Discover integration_test/desktop_*_test.dart and run real GUI tests.
      --os-input also requires real OS input capability; no permission is granted.
      Use an isolated GUI session: tests can move the pointer and create windows.
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
  receiver
      Shared control without Dart SDK, protocol or media backends.
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
    cmake -S "$project_root/native" -B "$project_root/build/macos-native" -DAIRPLAY_BUILD_TESTS=ON
    cmake --build "$project_root/build/macos-native" --target player_tests session_tests receiver_control_tests receiver_tests --parallel 8
    ctest --test-dir "$project_root/build/macos-native" --output-on-failure --no-tests=error -L 'receiver|ffi|playback' "$@"
}

macos_host() (
    require_macos_player
    mkdir -p "$project_root/build/native-tests"
    swiftc -import-objc-header "$project_root/macos/Runner/Receiver-Bridging-Header.h" \
        -L "$project_root/build/macos-native" -lairplay_player \
        -Xlinker -rpath -Xlinker "$project_root/build/macos-native" \
        "$project_root/native/apple/ReceiverHost.swift" "$project_root/macos/tests/host/main.swift" \
        -o "$project_root/build/native-tests/receiver-tests"
    "$project_root/build/native-tests/receiver-tests"
)

macos_texture() (
    require_macos_player
    test_root="$project_root/build/texture-tests"
    mkdir -p "$test_root"
    swiftc -emit-library -emit-module -module-name FlutterMacOS \
        "$project_root/macos/tests/texture/FlutterMacOS.swift" -o "$test_root/libFlutterMacOS.dylib"
    swiftc -import-objc-header "$project_root/macos/Runner/Receiver-Bridging-Header.h" \
        -I "$test_root" -L "$test_root" -lFlutterMacOS \
        -L "$project_root/build/macos-native" -lairplay_player \
        -Xlinker -rpath -Xlinker "$test_root" -Xlinker -rpath -Xlinker "$project_root/build/macos-native" \
        "$project_root/native/apple/ReceiverHost.swift" "$project_root/native/apple/FrameTexture.swift" \
        "$project_root/macos/tests/texture/main.swift" -o "$test_root/texture-tests"
    "$test_root/texture-tests"
)

macos_rtp() (
    require_macos_player
    cmake -S "$project_root/native" -B "$project_root/build/macos-native" -DAIRPLAY_BUILD_TESTS=ON
    cmake --build "$project_root/build/macos-native" --target protocol_rtp_tests --parallel 8
    ctest --test-dir "$project_root/build/macos-native" --output-on-failure --no-tests=error -R '^rtp$'
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
    cat "$project_root/macos/Runner/MainFlutterWindow.swift" "$project_root/macos/tests/window/main.swift" > "$test_root/main.swift"
    swiftc -F "$framework_root" -framework FlutterMacOS \
      -Xlinker -rpath -Xlinker "$framework_root" "$test_root/main.swift" -o "$test_root/window-tests"
    # Requires a logged-in macOS GUI session. AppKit performs real fullscreen transitions.
    "$test_root/window-tests"
)

alac_tests() (
    output="$project_root/build/alac-tests"
    cmake -S "$project_root/native/tests" -B "$output" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DAIRPLAY_SANITIZE="${ALAC_SANITIZE:-OFF}" -DAIRPLAY_TEST_FFMPEG=OFF
    cmake --build "$output" --target alac_tests --parallel 8
    ctest --test-dir "$output" --output-on-failure --no-tests=error
)

ffmpeg_tests() (
    output="$project_root/build/ffmpeg-video-tests"
    cmake -S "$project_root/native/tests" -B "$output" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DAIRPLAY_SANITIZE="${FFMPEG_SANITIZE:-OFF}" -DAIRPLAY_TEST_FFMPEG=ON
    cmake --build "$output" --target ffmpeg_video_tests --parallel 8
    ctest --test-dir "$output" --output-on-failure --no-tests=error
)

android_host() (
    python3 "$project_root/scripts/fetch_native_deps.py"
    mkdir -p "$project_root/artifacts/android"
    cmake -S "$project_root/android/tests" -B "$project_root/build/android-core-host" -DCMAKE_BUILD_TYPE=Debug \
        -DHOST_SANITIZE="${HOST_SANITIZE:-OFF}" \
        -DUXPLAY_SOURCE="$project_root/vendor/UxPlay" \
        -DPLIST_SOURCE="$project_root/build/native-deps/libplist" -DCRYPTO_PREFIX="${HOST_CRYPTO_PREFIX:-}"
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
    ndk_version=$(sed -n 's/^airplay\.ndkVersion=//p' "$project_root/android/gradle.properties")
    native_output="$project_root/build/android-native-arm64-$ndk_version"
    [[ -f "$native_output/CMakeCache.txt" ]] || fail 'Build the Android native player first.'
    cmake="$sdk/cmake/3.22.1/bin/cmake"
    "$cmake" -S "$project_root/android/app/src/main/cpp" -B "$native_output" -DAIRPLAY_ANDROID_BUILD_TESTS=ON
    "$cmake" --build "$native_output" --target player_regression --parallel 8
    cp "$native_output/libplayer_regression.so" "$output/lib/arm64-v8a/"
    cp "$project_root/android/app/src/main/jniLibs/arm64-v8a/libairplay_player.so" "$output/lib/arm64-v8a/"
    javac -source 17 -target 17 -cp "$sdk/platforms/android-36/android.jar" \
        -d "$output/classes" "$project_root/android/tests/player/"*.java \
        "$project_root/native/backends/android/java/tech/soit/flutterairplay/audio/"*.java
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
            targets=(linux_player_tests linux_session_tests linux_audio_decoder_tests linux_audio_output_tests receiver_control_tests)
            test_args+=(-R '^(linux_(playback|sender_resume|audio_decode_recovery|audio_unavailable_cleanup)|receiver_control)$')
            ;;
        gpu)
            targets=(linux_gpu_tests)
            if [[ -f "$project_root/linux/flutter/ephemeral/libflutter_linux_gtk.so" ]]; then targets+=(linux_gl_texture_tests linux_synthetic_demo); fi
            test_args+=(-R '^linux_gpu_')
            ;;
        video) targets=(linux_video_tests); test_args+=(-R '^linux_video_reorder_recovery$') ;;
        host) targets=(linux_host_tests); test_args+=(-R '^linux_flutter_host_lifecycle$') ;;
        all) ;;
        *) fail "Unknown Linux suite: $suite. Use --help." ;;
    esac
    if [[ "${1:-}" == --filter ]]; then
        [[ $# -ge 2 ]] || fail 'Linux --filter requires a CTest regular expression.'
        test_args=(--no-tests=error -R "$2")
        shift 2
    fi
    if [[ "${1:-}" == --verbose ]]; then
        test_args+=(-V)
        shift
    fi
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

desktop_tests() (
    platform="$1"
    shift
    [[ $# -eq 0 || ( $# -eq 1 && "$1" == --os-input ) ]] ||
        fail 'desktop accepts only --os-input.'
    cd "$project_root"
    shopt -s nullglob
    tests=(integration_test/desktop_*_test.dart)
    [[ ${#tests[@]} -gt 0 ]] || fail 'No desktop integration tests discovered.'
    input=false
    if [[ "${1:-}" == --os-input ]]; then input=true; fi
    printf 'Desktop suite: %s; OS input requested: %s\n' "$platform" "$input"
    printf '  %s\n' "${tests[@]}"
    # Flutter runs integration files serially on the selected real desktop host.
    # An OS-input fixture must fail, not silently skip, when input was requested
    # but its platform/session cannot provide it. Never grant permissions here.
    # On Windows use the native launcher: bin/flutter's Unix script overwrites
    # the inherited OS environment variable with uname, breaking native tools.
    flutter_command=flutter
    if [[ "$platform" == windows ]]; then flutter_command=flutter.bat; fi
    "$flutter_command" test -d "$platform" "${tests[@]}" --reporter expanded \
        "--dart-define=AIRPLAY_OS_INPUT_TEST=$input"
)

macos_tests() {
    local suite="${1:-player}"
    if [[ $# -gt 0 ]]; then shift; fi
    if [[ "$suite" != player && $# -gt 0 ]]; then fail 'Only the player suite accepts CTest arguments.'; fi
    case "$suite" in
        all) macos_player; macos_host; macos_texture; macos_rtp; macos_window ;;
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
    if [[ "$suite" == installer ]]; then
        [[ $# -eq 1 ]] || fail 'Usage: scripts/test_native.sh windows installer <setup.exe>'
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$project_root/windows/scripts/test_installer.ps1" -Installer "$1"
        return
    fi
    if [[ "$suite" == texture ]]; then
        [[ -f "$project_root/build/windows/x64/CTestTestfile.cmake" ]] ||
            fail 'Prepare the Windows host with flutter build windows --debug first.'
        ctest --test-dir "$project_root/build/windows/x64" -C Debug --output-on-failure -R '^windows_texture$' "${test_args[@]}" "$@"
        return
    fi
    case "$suite" in
        player) test_args+=(-R '^(windows_(pixels|compat|httpd|audio_clock|audio_decode_recovery|startup)|receiver_(control|lifecycle))$') ;;
        video) test_args+=(-R '^windows_(video|video_gpu|hevc_software)$') ;;
        all) ;;
        *) fail "Unknown Windows suite: $suite. Use --help." ;;
    esac
    [[ -f "$project_root/build/windows-native/CTestTestfile.cmake" ]] ||
        fail 'Build Windows fixtures with windows/scripts/build_native.ps1 -Tests first.'
    ctest --test-dir "$project_root/build/windows-native" -C Release --output-on-failure "${test_args[@]}" "$@"
    if [[ "$suite" == all && $# -eq 0 ]]; then windows_tests texture; fi
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

# Desktop integration stays explicit; default native/player runs stay headless.
if [[ "$target" == macos || "$target" == linux || "$target" == windows ]] && [[ "${1:-}" == desktop ]]; then
    shift
    desktop_tests "$target" "$@"
    exit
fi

case "$target" in
    --help|-h) usage ;;
    build)
        [[ $# -eq 0 ]] || fail 'build does not accept extra arguments.'
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*)
                python "$project_root/tool/check_boundaries.py"
                python -m unittest discover -s "$project_root/scripts/tests" -p 'test_*.py'
                ;;
            *)
                python3 "$project_root/tool/check_boundaries.py"
                python3 -m unittest discover -s "$project_root/scripts/tests" -p 'test_*.py'
                ;;
        esac
        ;;
    receiver)
        receiver_configure=(cmake -S "$project_root/native" -B "$project_root/build/receiver-control")
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*) receiver_configure+=(-G 'Visual Studio 17 2022' -A x64 -T ClangCL) ;;
        esac
        "${receiver_configure[@]}" \
            -DCMAKE_BUILD_TYPE=Debug -DAIRPLAY_CONTROL_ONLY=ON \
            -DUXPLAY_SOURCE="$project_root/vendor/UxPlay" \
            -DPLIST_SOURCE="$project_root/build/native-deps/libplist"
        cmake --build "$project_root/build/receiver-control" --config Debug --target receiver_tests --parallel 8
        ctest --test-dir "$project_root/build/receiver-control" -C Debug --output-on-failure --no-tests=error
        ;;
    macos) macos_tests "$@" ;;
    linux)
        if [[ "${1:-}" == window ]]; then
            shift
            [[ $# -le 1 ]] || fail 'Linux window accepts one optional bundle path.'
            linux_window "$@"
        else
            linux_tests "$@"
            if [[ "${1:-}" == all && $# -eq 1 ]]; then linux_window; alac_tests; fi
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
