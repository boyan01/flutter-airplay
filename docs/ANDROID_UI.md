# Shared Flutter UI: Android host and input contract

The root Flutter application is the UI and state owner for macOS and Android.
`android/` embeds the previously validated Android receiver/player, preserving
application ID `io.github.boyan01.flutter_airplay`, Kotlin/JNI class names,
`receiver` preferences, app identity and `files/airplay-pairing.pem`. Installing
an update with the same signing key preserves pairing data. The former `android-player/` product entry point has been retired; its
native sources and licenses are maintained only under `android/`. Git history
preserves the migration reference.

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

Final integration on 2026-10-03: the root shared UI passes analyze and all 15
Flutter tests. Pinned OpenSSL/libplist/Oboe/FFmpeg source caches were verified
against lock-file commits and clean Git status before reuse from the earlier
local project. Receiver and player JNI libraries were rebuilt from source.
No prebuilt third-party APK or unverified dependency cache was used.

The release packaging guard was tested without the JNI library: `packageRelease`
failed with rebuild instructions. After native build the root arm64 APK passed
packaging and lint-vital, contains the source-built AArch64 `libairplay_player.so`
(byte-identical to the generated JNI input), `libapp.so`, `libflutter.so` and
nine license assets. APK signature verification passed.

Six `ReceiverStateTest` tests passed, zero skipped/failures/errors:

```sh
JAVA_HOME=/path/to/jdk GRADLE_BIN=/path/to/gradle
"$GRADLE_BIN" -p android :app:testDebugUnitTest -Ptarget-platform=android-arm64
```

The initial multi-ABI Debug dependency download stalled. Restricting the test
build to the actual arm64 target completed normally. The same six pure-state
tests also passed directly using cached Kotlin 2.2.21 and JUnit 4.13.2.

The final APK 0.1.2+3 was installed with `adb install -r` on the connected
Xiaomi 14 / 23127PN0CC / Android 16. Its signing certificate matches the installed
0.1.1+2 APK exactly. The prior APK was backed up privately; no uninstall, data
clear or keystore change occurred. The shared phone UI reached waiting after
NSD registration. Select-center and Enter activation, receiver stop/restart,
D-pad navigation, logs/Back with restored focus, immersive embedded preview and
Back without stopping reception were observed. App-scoped logs show no startup
crash or missing native library.

No physical TV was available. TV layout/focus use synthetic Flutter capabilities
and key events; phone D-pad input is not physical TV playback acceptance. The
prior user-confirmed iPhone discovery/image/sound belongs to APK 0.1.1+2;
new shared-UI iPhone image/sound, sync, rotation, reconnect and sustained playback
remain for sender acceptance. Artifact hashes and complete current scope are in
[SHARED_UI_VALIDATION.md](SHARED_UI_VALIDATION.md).
