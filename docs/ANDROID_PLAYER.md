# Android playable APK host

`android-player/` is an isolated Flutter Android application, package
`io.github.boyan01.flutter_airplay`, label **Flutter AirPlay**. It is distinct
from the earlier JNI validation harness. It embeds the video in a Flutter
texture and sends decoded audio to the Android output device.

## Scope

- Pinned UxPlay 1.73.7 core (root `native/uxplay.lock.json`), generated core and
  existing receive patch plus the Android lifetime patch.
- Real AirPlay/RAOP TCP listeners, pairing/decryption, UDP encoded audio and
  mirrored H.264 video reception.
- Android NSD publishes `_airplay._tcp` and `_raop._tcp`, with the core's TXT
  data and persisted random app identity/private pairing key in app storage.
- Android MediaCodec H.264 decoding and EGL rendering to a Flutter texture.
- Android MediaCodec AAC/AAC-ELD and FFmpeg ALAC decoding; Oboe output and the
  reference timeline buffer. UxPlay 1.73.7 Unix-local NTP timestamps are
  converted into the Android monotonic clock domain for these playback sinks.
- Application starts reception on opening. Start/stop/name editing and errors
  are functional; ready status follows successful registration of both NSD
  services. Playing status follows a decoded MediaCodec output buffer.

The current host supports screen mirroring and associated audio. HLS/DRM and
HEVC playback are not advertised/accepted. Keep the application visible during
reception; a background/foreground-service lifecycle is a follow-up. Sender
volume does not alter system volume. The application uses the current device
volume, controlled by the user.

## Build and install

Use Flutter 3.47.2, Android SDK 36, NDK 28.2.13676358 and CMake 3.22.1. Gradle
9.3.1/AGP 9.1.0/Kotlin 2.2.21 are used by this standalone host. Its Android
minimum is API 26 and the currently built native ABI is arm64-v8a.

From the repository root:

```sh
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
python3 android-prototype/scripts/fetch_deps.py
./android-prototype/scripts/build_native.sh arm64-v8a
python3 android-player/scripts/fetch_deps.py
./android-player/scripts/build_native.sh
cd android-player
flutter pub get
flutter analyze
flutter build apk --release --target-platform android-arm64
adb -s DEVICE_SERIAL install -r build/app/outputs/flutter-apk/app-release.apk
adb -s DEVICE_SERIAL shell am start -n io.github.boyan01.flutter_airplay/.MainActivity
```

Release-mode builds currently use the local Android debug signing key for local
installation, not a public distribution/release signing key. Do not commit or
share signing keys. APKs and native dependency/build products are ignored.
For offline AGP resource packaging, the SDK aapt2 executable can be passed as
`-Pandroid.aapt2FromMavenOverride` to Gradle rather than downloading it.

## Shared Flutter integration contract

Control channel: `flutter_airplay/control`, `start` with a `name` string,
returns `textureId`, `width`, `height`, `name`; `stop` releases listener,
registration, audio and texture. Events channel: `flutter_airplay/events`,
objects contain `state` and `message`, or `width`/`height` changes.
States include starting, ready, waiting, playing, stopped and error. No desktop
presentation parameter is needed. Parent session can move the Kotlin/native
implementation into the main Android plugin and adapt these methods to the
main Flutter controller once its committed Mac checkpoint is available.

## Source provenance

GPL playback source is copied from jqssun/android-airplay-server commit
`c8defdd70d7e6a04f4f1b71d353653682d594106`; exact paths are listed in
`android-player/dependencies.lock.json`, modifications in `android-player/NOTICE`.
The reference's package names remain on copied renderer classes. The app itself
has its own package ID and Flutter host. Oboe and minimal FFmpeg sources are
pinned separately and their licenses, core/dependency licenses and reference
GPL license are packaged in APK assets. No third-party prebuilt APK is used.

## Validation record

Build/installation/discovery observations must be recorded separately from
real sender playback. A built APK or registered NSD services alone do not prove
an iPhone connection, visible mirrored frames, audible sound, or A/V sync.
The earlier core harness and synthetic regression results belong to
`docs/ANDROID.md` and are not playback acceptance evidence for this app.

Completed on 2026-10-03: arm64 native library build; Flutter analyze with no
issues; Gradle release APK build and release lint-vital checks; APK signature
verification; successful installation and launch on a physical Xiaomi 14
(23127PN0CC, Android 16/API 36, arm64). The visible app reached ready after
both NSD registrations completed, showing **Flutter AirPlay Android** as its
receiver name. App-scoped runtime logs contained no crash at startup. This
is actual receiver startup/discovery observation, not an iPhone playback claim.
No iPhone frame, sound or synchronization observation has been completed here.

The APK contains only arm64 native libraries (receiver/player, Flutter app,
Flutter engine), nine bundled license files, and is 26,746,428 bytes.
SHA-256: `3eaccb6173e1f3aa856e33ac56dfd6414bde6476d6c3f6b30dae7c4d7465e87a`.

Discovery correction: the initial APK cleared feature bit 7 by mistake.
UxPlay's feature table defines bit 7 as screen mirroring; HLS uses bits 0/4.
Version 0.1.1+2 retains bit 7, disables HLS 0/4 and HEVC 42. The updated APK
was installed and restarted on the physical device. An independent LAN DNS-SD
lookup confirmed `features=0x5A7FFEE6,0x0` (initial incorrect value
`0x5A7FFE66,0x0`) and a reachable advertised TCP endpoint. User confirmation
of iPhone discovery/connection and playback is still pending.
