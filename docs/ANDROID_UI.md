# Shared Flutter UI: Android host and input contract

The root Flutter application is the UI and state owner for macOS and Android.
`android/` embeds the previously validated Android receiver/player, preserving
application ID `io.github.boyan01.flutter_airplay`, Kotlin/JNI class names,
`receiver` preferences, app identity and `files/airplay-pairing.pem`. Installing
an update with the same signing key preserves pairing data. `android-player/`
is retained temporarily as the migration reference; its Dart UI is not the
entry point for the root Android APK.

## Shared API

Control: `org.airplayreceiver/control`. Events: `org.airplayreceiver/events`.
All host state and Flutter event delivery are serialized on Android's main
thread; JNI reception and playback keep their existing worker threads.

| Method | Arguments | Result / behavior |
| --- | --- | --- |
| `snapshot` | none | Complete state map below; does not start reception |
| `save` | `name`, `path` | Validate and persist the trimmed receiver name while stopped |
| `check` | `path` | Enumerate H.264/AAC decoders; native library has loaded; no network listener or audio output is started |
| `start` | `name`, `path` | Use the existing JNI receiver, NSD services and playback surface; returns null when the listener and registrations are requested |
| `stop` | none | Stop reception, unregister discovery, release playback and texture; returns null after cleanup |

Android requires `path` to be empty or whitespace. A nonempty path returns
an actionable platform error; there is no external executable/GStreamer
setting on Android. Names match the shared model's 1–50 UTF-8-byte limit and
reject ASCII control characters. Name persistence does not change app identity
or pairing keys. `save` and `check` reject an active receiver.

Snapshot schema (the bridge also sends `{"type":"snapshot","data":...}` on
subscription and state/size changes):

```json
{
  "status": "stopped",
  "message": "接收器未启动",
  "pid": 0,
  "name": "Flutter AirPlay Android",
  "path": "",
  "textureId": -1,
  "videoWidth": 0,
  "videoHeight": 0,
  "logs": [{"id": 1, "time": "2026-10-03T00:00:00Z", "text": "..."}],
  "capabilities": {
    "platform": "android",
    "isTelevision": false,
    "supportsExecutablePath": false
  }
}
```

`isTelevision` comes from `UiModeManager.currentModeType`, not screen size.
`pid` is the actual app PID only while the native host owns or is preparing /
cleaning up a receiver; it is zero when idle. It does not denote a subprocess.
This keeps the root model's stop action available if decoding fails while the
native receiver is still active. Logs have monotonic IDs, ISO timestamps,
at most 300 entries and at most 4096 characters per entry.

Legacy `ready` and `waiting` map to shared `waiting`; `playing` maps to
`streaming` only after a decoded MediaCodec output buffer. Dimensions are zero
outside `streaming`. A disconnect/reset hides stale video; the first decoded
frame on reconnect restores the retained texture/dimensions. Registration
failures survive automatic cleanup as `error`; an explicit stop clears them.
`check` passing does not prove actual playback or codec allocation success.

## UI / remote integration requirements

The shared UI should consume `capabilities` and hide the executable-path field
and GStreamer instructions when `supportsExecutablePath` is false. Android
uses the shared name/start/stop/settings controls and the shared embedded
Flutter texture. No protocol or separate Android Dart UI is needed.

Use the TV capability for a readable 10-foot layout with overscan margins;
phone portrait/landscape use available bounds. Start focus on a useful action,
show a high-contrast focus border, support all four D-pad directions plus
center/Enter, and restore focus to the originating action after closing
settings/diagnostics. All actions must be usable without touch or a mouse.

While playing, touch or D-pad/center can reveal controls. Controls should stay
visible until deliberately hidden, and a focusable playback target must remain
when hidden. Back closes the nearest secondary surface, then exits fullscreen,
then returns to the main view without stopping reception. Leaving an active
receiver must be deliberate. System/remote Back must share the same policy.

The Android manifest adds `LEANBACK_LAUNCHER`, optional `android.software.leanback`,
optional touchscreen and a 320×180 xhdpi banner. These follow the
[Android TV launcher requirements](https://developer.android.com/training/tv/get-started/create).
Phone launcher, package name and existing network/multicast permissions are
preserved; no new permission or system/network/volume setting is introduced.
The shipped native ABI remains arm64-v8a; these declarations alone do not
establish TV hardware or x86 TV-emulator compatibility.

## Build

From repository root (installed Flutter 3.47.2 / SDK 36 / NDK 28.2.13676358 /
CMake 3.22.1; local release builds use the existing debug signing convention):

```sh
ANDROID_HOME="$HOME/Library/Android/sdk" ./android-prototype/scripts/build_native.sh arm64-v8a
python3 android/scripts/fetch_deps.py
./android/scripts/build_native.sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64 --build-name 0.1.2 --build-number 3
```

Native libraries are generated under ignored `android/app/src/main/jniLibs/`.
The APK entry point is root `lib/main.dart`. Keep GPL/source provenance notices
and bundled license assets with the migrated sources.

## Validation record

Migration checkpoint on 2026-10-03: root `flutter analyze` passed and all nine
existing root Flutter tests passed. A preliminary root release build compiled
the migrated Kotlin bridge and passed release packaging/lint-vital, but did
not yet contain the native player library. It is not an installable acceptance
artifact. Packaging now rejects a missing native library with rebuild steps;
this new guard still needs its own build verification. The pinned OpenSSL
clone stalled and was cancelled at the handoff boundary; no complete native
build was performed in this clone.

Six `ReceiverStateTest` regressions have been added. The attempted
`:app:testDebugUnitTest --offline` was blocked before test execution because
the debug Flutter embedding/ABI JARs are absent from the Gradle cache. Rerun
online with the installed Gradle 9.3.1 executable (or the generated wrapper)
after dependencies are available. No unit-test success is claimed.

Final shared-UI integration and device acceptance are pending. Initial physical
device read-only inspection on 2026-10-03: `e19b9bc1`, Xiaomi 14 / 23127PN0CC,
Android 16; foreground app is `io.github.boyan01.flutter_airplay`, installed
version 0.1.1+2. No app update has been installed during migration preparation.
The prior user-confirmed iPhone image/audio acceptance belongs to that earlier
APK; it does not establish acceptance of the migrated/shared-UI APK.
