# Flutter AirPlay development handoff

## Repository and ownership

Public repository: https://github.com/boyan01/flutter-airplay . Branch: `main`.
This macOS embedded checkpoint follows published baseline
`e6819bbd6f6cad0dec2c0a6337944cbc3fe90a42`. Read `git status` before editing;
never reset or overwrite another session's working-tree changes.

The macOS feature owner covers `macos/**`, Dart preview/model/repository,
patch 0002 and frame/sync fixtures. Android work is in a separate workflow and
must coordinate any shared Dart, pubspec, root build or documentation change.
The parent integration session owns the cross-platform summary/integration.

The shared-UI integration now maintains a single root Flutter project for macOS,
Android phones and TV. Native Android playback moved from the former
`android-player/` product to root `android/`; the old product entry point was
retired, with history preserved in Git. Both hosts use the shared receiver
channel/model/screen. See [SHARED_UI_VALIDATION.md](SHARED_UI_VALIDATION.md) for
0.1.2+3 build, signature and actual UI/device acceptance. Historical Android
user-confirmed image/sound remains in [ANDROID_PLAYER.md](ANDROID_PLAYER.md).
The remaining macOS checkpoint sections below are historical context.

## Current macOS path

UxPlay v1.73.7 + GStreamer own AirPlay receiving, software H264 decode,
macOS audio and the shared presentation clock. Flutter owns controls and
preview. No Go component. Preserve receive/playback boundaries and GPL notices.

Patch 0001 retains state markers, audio diagnostics, shared clock, RTP epoch
reset, bad AAC timestamp rejection and same-codec SETUP/FLUSH recovery.
Patch 0002 adds BGRA appsink and a sender thread with one in-flight and one
replaceable pending frame. Socket send timeout/drop keeps network I/O off the
streaming thread. Video stop invalidates pending/in-flight transport epochs.
`vendor/UxPlay` remains pristine at `native/uxplay.lock.json`; edit generated
`build/uxplay-src` and regenerate ordered `native/patches`.

Embedded helper arguments are `-rc /dev/null -n <name> -nh -vsync -avdec
-vs appsink -vc "videoconvert ! video/x-raw,format=BGRA" -as osxaudiosink`.
The macOS product now supports only embedded playback, per the latest user
requirement. There is no presentation selector, persisted mode or glimagesink
startup branch. The Dart start/save interface remains platform neutral. Native
lifecycle fixtures inject a test-only video output, rather than a window fallback.

Swift creates a session-owned private temporary Unix socket (directory 0700,
socket 0600). Wire header is eight little-endian u32: FPV1 magic, version 1,
width, height, packed stride, payload size, sequence, reserved zero. Dimensions
are limited to 4096 per axis. Malformed/truncated clients are dropped.
Disconnect clears the current connection epoch while keeping the listener for
reconnect. Stop/quit synchronously removes owned socket directories before app exit.

FrameTexture copies BGRA into Metal-compatible IOSurface CVPixelBuffer and
coalesces notifications from current state. It registers once on the first Dart
request, after engine startup; registering in awakeFromNib caused ID-zero black
output and must not be reintroduced. Window close/quit or bridge replacement
shuts down the owned process and unregisters the texture before engine disposal.
Only texture ID and dimensions cross Dart; pixels are never logged or persisted.
This path is copied, not zero-copy/VideoToolbox hardware decoding.

The UI shows application preview only. Expanded
preview supports Esc return; macOS native fullscreen is also available.
`org.flutterairplay.receiver` separates the new bundle and preferences from the
historical recovery prototype. Launch the Release bundle from `build/macos/Build/
Products/Release/Flutter AirPlay.app`. The final application was left ready for
an iPhone to reconnect to device name `Flutter AirPlay`.

## Completed scope and remaining acceptance

See [VALIDATION.md](VALIDATION.md) for the precise synthetic and CUA scope.
Native build; analyze; 9 Flutter tests; all five existing native suites; new
appsink/socket/texture suites; Release 46.8 MB; and local signature verify pass.
CUA confirmed synthetic visible landscape/portrait Texture, both fullscreen
modes, Esc, stop-to-placeholder, start/restart, Cmd-Q and active-window-close process cleanup.

A real iPhone connected and produced decode events. User-confirmed new-build
image, audible sound, sync, rotation, reconnect and sustained playback remain
separate. IPv6 NTP `No route to host` was observed; do not hide it or treat
synthetic timing as true-device success. The prototype's prior user acceptance
is historical only. Its running instance was closed and its app bundle retained as history only;
there is no separately maintained standalone product.
Do not change system security, AirPlay Receiver, network, volume or credentials.

Ignored evidence is under `artifacts/validation/mac-review-*`. Do not commit
runtime logs, screenshots, machine/user paths, device/network IDs or binaries.
The app still links Homebrew libraries and is a local unsandboxed development
build; no distribution signing/notarization or Intel/Android support is claimed.

## Build and regression commands

```sh
./scripts/build_receiver.sh
flutter analyze
flutter test
./scripts/test_frames.sh
./scripts/test_native.sh "$PWD/native/receiver/uxplay"
./scripts/test_audio.sh
./scripts/test_sync.sh
./scripts/test_rtp.sh
./scripts/test_recovery.sh
flutter build macos
```

Frame tests build a test-only FlutterMacOS interface shim to execute the actual
FrameTexture without an engine. It lives only in `build/frame-tests` and must
never be linked into Runner. CUA visible-output acceptance complements that test.
