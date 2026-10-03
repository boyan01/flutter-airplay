# Shared root UI integration acceptance — 2026-10-03

Version **0.1.2+3**. One product Flutter entry point: root `lib/main.dart`.
macOS and Android hosts consume the same screen/model/platform contract.
The former `android-player/` product files are retired; native implementation,
locks and licenses are maintained under `android/`. Git retains their history.
`android-prototype/` remains the native foundation and device test harness.

## Completed builds and tests

| Check | Completed scope |
| --- | --- |
| `flutter analyze` | No issues |
| `flutter test` | 15 passing model/widget tests; fake repositories/video metadata |
| `./scripts/build_receiver.sh` | Pinned UxPlay verified; native Mac Release rebuilt |
| Native regression scripts | `test_native`, `test_audio`, `test_sync`, `test_rtp`, `test_recovery`, `test_frames` all pass; synthetic/test-owned processes and inputs |
| `flutter build macos --release` | Final 47.4 MB local development app, version 0.1.2+3 |
| `codesign --verify --deep --strict` | Passes final build and two Dart-only incremental rebuilds after declared embed outputs fix |
| Android core/player scripts | Rebuilt arm64 JNI from clean sources with exact lock-file SHAs |
| Missing-JNI packaging guard | Actual `packageRelease` failure before JNI build; actionable rebuild message |
| `flutter build apk --release --target-platform android-arm64` | Root Flutter APK, release packaging/lint-vital passed |
| APK inspection/signature | AArch64 ELF JNI matches generated source-built library; nine license assets; APK v2 signature verified |
| `:app:testDebugUnitTest -Ptarget-platform=android-arm64` | Gradle success; six state-adapter tests, zero skips/failures/errors |

The earlier isolated Mac checkpoint failed because the outer app sealed an old
framework CDHash while `App.framework` itself remained valid. The Xcode Flutter
embed phase now declares generated framework outputs. Normal Xcode signing
refreshes the outer app when Dart changes. No security settings, signing account
or credentials were changed; ad-hoc development signing remains in use.

## Visible / device acceptance

macOS CUA observed the new UI, cancel/Escape discarding a name draft, window zoom
resize, native fullscreen/Escape, embedded expanded preview/Escape, startup and
waiting. The historical app is preserved in its previous project; the final root
app is running and waiting as **Flutter AirPlay**. This session did not connect
an iPhone or inject a visible synthetic video into the final UI.

Physical Android: Xiaomi 14 (23127PN0CC), Android 16/API 36, arm64.
Updated from 0.1.1+2 with `adb install -r`, identical debug certificate; old APK
backed up in ignored artifacts. No uninstall or data clear. Visible shared UI,
Select-center/Enter activation, D-pad navigation, start/stop/restart, logs/Back
with restored focus, immersive expanded preview and Back retaining reception
passed. Final app is waiting as **Flutter AirPlay Android**. Scoped runtime logs
contain no AndroidRuntime fatal, missing JNI or fatal native signal.

TV uses capability-driven Flutter widget tests and phone-simulated D-pad events.
No real TV hardware or x86 TV-emulator playback was tested.

## Final Android artifact

`build/app/outputs/flutter-apk/app-release.apk`, 26,600,800 bytes.
SHA-256: `7e84ff81c991c65a0d9b981499da2003aae532591ca3055f0ca61612b7d79c9c`.
Contains `lib/arm64-v8a/{libairplay_player.so,libapp.so,libflutter.so}`.
Signing certificate SHA-256:
`24226ee39ab707cb4e7ddea0c653619eb365eb1d1006391070908958c779585e`.
This is the existing local debug-signing convention, not a distribution key.

Local logs/screenshots/previous APK are under ignored `artifacts/`; SDK and
keystore files, generated JNI, APKs, Mac app and dependency caches are excluded
from public source. Vendored UxPlay and native media patches were not modified.

## Remaining sender / distribution acceptance

New shared-build real iPhone image, audible sound, A/V synchronization, sender
rotation, reconnect and sustained playback have not been confirmed. Historical
user-confirmed Android 0.1.1+2 image/sound is kept separately in
[ANDROID_PLAYER.md](ANDROID_PLAYER.md). Synthetic tests cannot establish these.
Mac still depends on local Homebrew libraries; Developer ID/notarization,
portable Mac packaging, other Android ABIs and physical TV support remain outside
this completed local-build/UI acceptance. No standalone Mac playback mode exists.
