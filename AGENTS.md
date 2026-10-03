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
  `native/player/` owns shared playback and receiver lifecycle; platform hosts
  adapt textures, discovery and application lifecycle.
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

Requires Xcode's macOS SDK, CMake, Python 3 and Perl on Apple Silicon.
The script fetches verified sources from `android/dependencies.lock.json`.
Intel has not been validated.

```sh
brew install cmake
./scripts/build_receiver.sh
flutter run -d macos
# Build and launch the Release application:
flutter build macos --release
open "build/macos/Build/Products/Release/Flutter AirPlay.app"
```

The native script builds the shared C++ player in `build/macos-native/`, with
static OpenSSL and libplist. Xcode links and bundles this library;
VideoToolbox, AudioConverter, CoreAudio and Bonjour are system dependencies. Build native code
before building Flutter. For an audited ad-hoc signed application and ZIP:

```sh
./scripts/package_macos.sh
```

The package has no Homebrew runtime dependency. Developer ID signing and
notarization are separate distribution steps.

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

macOS native regressions, after building the shared player:

```sh
./scripts/test_player.sh
./scripts/test_native.sh
./scripts/test_frames.sh
./scripts/test_rtp.sh
```

These use synthetic audio/video and loopback protocol inputs. The former
GStreamer and Kotlin/EGL playback fixtures were replaced with tests of the
current C++ player and direct Flutter texture adapter.

The standalone Android ALAC decoder also has a host regression for bit-exact
PCM, malformed packets and recovery: `ALAC_SANITIZE=ON ./scripts/test_alac.sh`.

For macOS window changes, build the Debug application and run
`./scripts/test_window.sh` in a logged-in macOS GUI session.

Android receive-core host regressions require CMake and native OpenSSL:

```sh
HOST_CRYPTO_PREFIX="$(brew --prefix openssl@3)" ./android/scripts/test_host.sh
HOST_CRYPTO_PREFIX="$(brew --prefix openssl@3)" HOST_SANITIZE=ON ./android/scripts/test_host.sh
```

These fixtures exercise the shared receive core and DNS/TXT adapter with
synthetic inputs; they are not the Android product's JNI playback host.
The platform playback regression builds a separate fixture app linked to the
packaged player. It requires an authorized arm64 device, JDK 17+, SDK build-tools
36.0.0 and the `android` CLI:

```sh
./scripts/test_android_player.sh
```

It decodes synthetic H.264 into a GPU SurfaceTexture, checks pixel data and
orientation, decodes synthetic AAC/ALAC/AAC-ELD, and opens/restarts silent Oboe
output. It uses a separate application ID and preserves the receiver app.
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
