# Flutter AirPlay development

## Working conventions

- Reply in Chinese. Keep code, comments and commit messages in English; follow
  the existing language when editing documents.
- Explain the outcome first, using short, direct sentences. Distinguish current
  behavior, code dependencies and design requirements.
- Confirm that new logic is necessary before adding it. Prefer existing
  abstractions and keep the change small.
- Show an ASCII UI sketch when changing UI or UX.
- Keep commit messages, PR titles and branch names free of `[codex]` or `codex/`
  prefixes.
- In code reviews, include every actionable finding in selectable Markdown in
  the final response: priority, file and line, failure scenario, and safe remedy.
  Inline comments may supplement this list.

## Documentation

Keep `README.md` focused on the product: purpose, current features, usage and
platform/runtime constraints. Commit descriptions, task history, per-task test
or acceptance results and user-confirmation records belong in task reports,
not in the README.

## Source and product boundaries

- Maintain one root Flutter application for macOS, Android phones and TV, with
  `lib/main.dart` as its entry point. Keep shared UI and receiver state in `lib/`;
  platform hosts own reception, rendering, audio and lifecycle.
- Maintain macOS playback inside the application. Do not add a standalone-window
  product mode or a Go component.
- Edit the shared receive core directly in `vendor/UxPlay/`. Both platforms build
  this source; preserve the receive/playback boundary and GPL notices. Record
  upstream updates in `vendor/UxPlay/UPSTREAM.md`.
- Keep generated build products in ignored output directories and local evidence
  in `artifacts/`. Keep logs, screenshots, binaries, credentials and device or
  network identifiers out of public source.

## Build and run

Run commands from the repository root. Use the Flutter version pinned in
`.fvmrc`; replace `flutter` with `fvm flutter` when using FVM.
Run `flutter pub get` before building either platform.

### macOS

Requires Xcode's macOS SDK and the native dependencies below. The current
build uses Homebrew on Apple Silicon; Intel has not been validated.

```sh
brew install cmake pkg-config libplist openssl@3 gstreamer
./scripts/build_receiver.sh
flutter run -d macos
# Build and launch the Release application:
flutter build macos --release
open "build/macos/Build/Products/Release/Flutter AirPlay.app"
```

The native script builds `vendor/UxPlay/` in `build/uxplay-native/` and copies
its receiver to `native/receiver/uxplay`. The application bundles that receiver
but still depends on local Homebrew libraries and plugins. It is an unsandboxed
local development build, not a portable signed/notarized distribution.
A custom receiver path must use this project's event protocol; stock Homebrew
UxPlay cannot complete the host's startup handshake.

### Android

The native build script currently targets a macOS development host. Install the
Android SDK, NDK 28.2.13676358 and SDK CMake 3.22.1. The product packages
arm64-v8a only and requires Android API 26 or newer.

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
./android/scripts/build_native.sh
flutter build apk --release --target-platform android-arm64
```

The script fetches and verifies dependencies from `android/dependencies.lock.json`
and builds OpenSSL and the JNI player. Caches live in ignored `android/.cache/`;
native output lives in `build/android-native-arm64/` and is copied into
`android/app/src/main/jniLibs/arm64-v8a/libairplay_player.so`.
APK packaging rejects a missing JNI library; build native code first.

The APK is `build/app/outputs/flutter-apk/app-release.apk`. Local Release builds
use debug signing. When installing an authorized device update, use
`adb install -r` with the same application ID and signing key to retain data.

## Validation

Run checks that match the changed code. Shared receive-core changes require both
macOS and Android builds and the relevant native regressions. Rebuild the native
receiver/player before packaging an application that uses changed native code.
Documentation-only changes require link and diff checks; they do not require
application builds.

Flutter checks:

```sh
flutter analyze
flutter test
```

macOS native regressions, after building the receiver:

```sh
./scripts/test_native.sh "$PWD/native/receiver/uxplay"
./scripts/test_frames.sh
./scripts/test_audio.sh
./scripts/test_sync.sh
./scripts/test_rtp.sh
./scripts/test_recovery.sh
```

For macOS window changes, build the Debug application and run
`./scripts/test_window.sh` in a logged-in macOS GUI session.

Android receive-core host regressions require CMake and native OpenSSL:

```sh
HOST_CRYPTO_PREFIX="$(brew --prefix openssl@3)" ./android/scripts/test_host.sh
HOST_CRYPTO_PREFIX="$(brew --prefix openssl@3)" HOST_SANITIZE=ON ./android/scripts/test_host.sh
```

These fixtures exercise the shared receive core and DNS/TXT adapter with
synthetic inputs; they are not the Android product's JNI playback host.
For Kotlin state-adapter changes, use the configured Gradle executable and JDK:

```sh
"$GRADLE_BIN" -p android :app:testDebugUnitTest -Ptarget-platform=android-arm64
```

Report the exact checks completed, their input and remaining gaps. Synthetic
results, build success and receiver state events do not establish real iPhone
image, audible sound, synchronization or Android-device support. Tie results to
the tested build and report them in the final response and PR description when
creating a PR. Follow the documentation scope above when editing `README.md`.

When updating dependencies or preparing distribution, read
`THIRD_PARTY_NOTICES.md` and preserve the bundled license assets.
