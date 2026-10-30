#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<'HELP'
Usage: ./scripts/test_native.sh [target] [suite] [arguments]

Without a target, run the current OS's basic native suite.
  macos [player|all|host|texture|rtp]
      player is the default; all adds host, texture and RTP/crypto tests.
      player accepts CTest arguments, e.g. macos player -R playback.
  linux [player|host|all] [--filter CTest-regex] [--verbose] [CMake arguments]
      player is the default; all includes the available Flutter host test.
  windows [player|texture|all] [CTest arguments]
      player is the default.
      Builds the fixtures in the nested native build of flutter build windows --debug.
      Argument-free all includes texture; extra arguments select native CTest only.
      texture uses windows_texture_test built in the Flutter Windows project.
      installer <setup.exe> checks install, upgrade, startup and uninstall.
      Invoke this script with Bash from the configured Windows toolchain.
  android [host|rtp|kotlin]
      host is the default; RTP is separate to avoid duplicate host runs.
  ios
      XCTest on an existing iPad simulator (IOS_TEST_DESTINATION optional).
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
    cmake -S "$project_root/native/apple" -B "$project_root/build/macos-native" -DAIRPLAY_BUILD_TESTS=ON
    cmake --build "$project_root/build/macos-native" --target receiver_control_tests receiver_tests --parallel 8
    ctest --test-dir "$project_root/build/macos-native" --output-on-failure --no-tests=error -L 'receiver|ffi' "$@"
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
    cat "$project_root/macos/Runner/VideoSurface.swift" "$project_root/macos/tests/texture/main.swift" > "$test_root/main.swift"
    swiftc -import-objc-header "$project_root/macos/Runner/Receiver-Bridging-Header.h" \
        -I "$test_root" -L "$test_root" -lFlutterMacOS \
        -L "$project_root/build/macos-native" -lairplay_player \
        -Xlinker -rpath -Xlinker "$test_root" -Xlinker -rpath -Xlinker "$project_root/build/macos-native" \
        "$project_root/native/apple/ReceiverHost.swift" "$project_root/native/apple/FrameTexture.swift" \
        "$test_root/main.swift" -o "$test_root/texture-tests"
    "$test_root/texture-tests"
)

macos_rtp() (
    require_macos_player
    cmake -S "$project_root/native/apple" -B "$project_root/build/macos-native" -DAIRPLAY_BUILD_TESTS=ON
    cmake --build "$project_root/build/macos-native" --target protocol_rtp_tests protocol_crypto_tests --parallel 8
    ctest --test-dir "$project_root/build/macos-native" --output-on-failure --no-tests=error -R '^(rtp|crypto)$'
)

android_host() (
    mkdir -p "$project_root/artifacts/android"
    cmake -S "$project_root/android/tests" -B "$project_root/build/android-core-host" -DCMAKE_BUILD_TYPE=Debug \
        -DHOST_SANITIZE="${HOST_SANITIZE:-OFF}"
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
    # Regenerates the plugins' Swift package for the app's deployment target.
    flutter build ios --config-only --simulator --debug
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
            targets=(receiver_control_tests receiver_tests protocol_crypto_tests)
            test_args+=(-R '^(crypto|receiver_(control|lifecycle))$')
            ;;
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
        *) fail "Unknown macOS suite: $suite. Use --help." ;;
    esac
}

android_tests() {
    local suite="${1:-host}"
    if [[ $# -gt 0 ]]; then shift; fi
    [[ $# -eq 0 ]] || fail 'Android suites take no arguments.'
    case "$suite" in
        host) android_host ;;
        rtp) android_host rtp ;;
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
        player) test_args+=(-R '^(crypto|windows_(compat|httpd|startup)|receiver_(control|lifecycle))$') ;;
        all) ;;
        *) fail "Unknown Windows suite: $suite. Use --help." ;;
    esac
    # The Flutter build configures the nested native player build and builds
    # lychee_player.dll, which the fixtures load.
    local native="$project_root/build/windows/x64/native"
    local runtime="$project_root/build/windows/x64/runner/Debug"
    [[ -f "$native/CMakeCache.txt" && -f "$runtime/lychee_player.dll" ]] ||
        fail 'Prepare the Windows host with flutter build windows --debug first.'
    cmake -S "$project_root/windows/player" -B "$native" -DAIRPLAY_WINDOWS_BUILD_TESTS=ON
    cmake --build "$native" --config Release --parallel
    PATH="$runtime:$PATH" ctest --test-dir "$native" -C Release --output-on-failure "${test_args[@]}" "$@"
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
            -DCMAKE_BUILD_TYPE=Debug -DAIRPLAY_CONTROL_ONLY=ON
        cmake --build "$project_root/build/receiver-control" --config Debug --target receiver_tests --parallel 8
        ctest --test-dir "$project_root/build/receiver-control" -C Debug --output-on-failure --no-tests=error
        ;;
    macos) macos_tests "$@" ;;
    linux) linux_tests "$@" ;;
    windows) windows_tests "$@" ;;
    android) android_tests "$@" ;;
    ios)
        [[ $# -eq 0 ]] || fail "$target does not accept extra arguments. Use --help."
        ios_tests
        ;;
    *) fail "Unknown target: $target. Use --help." ;;
esac
