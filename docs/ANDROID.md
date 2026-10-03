# Android foundation and integration handoff

## Current deliverable

`android-prototype/` is an independent Android library rooted at the committed
`e6819bbd6f6cad0dec2c0a6337944cbc3fe90a42` baseline. It can build an AAR with
arm64-v8a and x86_64 native libraries. It does not yet add Android support to the
Flutter application: no Flutter scaffold, decoder, audio output, receiver
foreground service or Flutter texture implementation is included. The separate
`device-harness/` APK contains a diagnostic activity and instrumentation runner;
it reports its synthetic scope explicitly and does not advertise AirPlay.

The actual locked UxPlay receive core is compiled, including pairing, HTTP/RTSP,
RTP, mirroring decryption, llhttp and PlayFair. The existing project's RTP recovery
core patch is applied. Neither macOS renderer nor GStreamer is linked. All
vendored hashes are verified before preparing `build/android-uxplay-src`.
Android's extra lifetime patch stays under this module's `patches/` to avoid
concurrent edits to shared `native/patches`; the integration owner can later
move it into the common patch workflow if desired.

`NativeReceiver` binds an ephemeral port and owns one receiver per process. It
requires a six-byte persisted random **app identity**, not a Wi-Fi hardware MAC,
and a private app-files pairing-key path. It exposes prepared TXT records and
polling of copied compressed media packets. RTP threads never call Java. An
opaque generation handle protects against stale JNI close/poll calls. Native
callbacks are joined before freeing receiver state. Default logging is silent.

`DiscoveryRegistration` is an explicit, separate NSD step. Call it only after a
usable playback sink is prepared. Two actual NSD success callbacks are required
for registration readiness; name-conflict results and failures reach the caller.
Late successful registrations are unregistered after close. Close discovery
before closing the core, and treat unregister failures as visible failures.
The DNS-SD C adapter only stores the core's TXT bytes; it does not advertise
services or claim network readiness on its own.

Packets retain video codec or audio `ct`, local NTP timestamp in **Unix wall-clock
nanoseconds**, RTP timestamp, audio sync status and queue epoch. They are not
decoded frames or PCM. A maximum of 128 packets / 8 MiB is retained, with video
input bounded to 2 MiB and audio input to 64 KiB. Overflow clears the compressed
decode epoch. A consumer must flush on epoch changes and wait for codec
configuration plus a decodable keyframe; it must not render arbitrary remaining
P-frames. `epoch()` exposes a flush even when no subsequent packet arrives.

## Build and tests

Prerequisites: an already licensed SDK with API 36 and build-tools 36.0.0,
NDK 28.2.13676358, CMake 3.22.1, a JDK, Gradle 9.3.1, Python 3, Git, Perl and make.
The standalone AAR uses AGP 9.1.0 and Java 17 bytecode; it has no extra Maven
runtime dependency. The library's minSdk is 26. It does not set the consuming
application's targetSdk. No tool updates, SDK installation or license acceptance
is performed by these scripts.

Set `ANDROID_HOME`, `JAVA_HOME`, `GRADLE_BIN` and `HOST_CRYPTO_PREFIX` to local
installations; do not commit their absolute values. From the repository root:

```sh
python3 android-prototype/scripts/fetch_deps.py
android-prototype/scripts/build_native.sh arm64-v8a x86_64
android-prototype/scripts/test_host.sh
(cd android-prototype && "$GRADLE_BIN" --no-daemon assembleDebug lintDebug)
python3 android-prototype/scripts/check_aar.py
(cd android-prototype && "$GRADLE_BIN" :device-harness:assembleDebug :device-harness:lintDebug)
# Select a device explicitly via ANDROID_SERIAL before this opt-in install/run:
android-prototype/scripts/test_device.sh
```

`build_native.sh` prepares source dependencies in ignored `.cache/`, builds
OpenSSL per ABI, compiles the actual core, and copies stripped libraries into
ignored `src/main/jniLibs/`. The final AAR is
`android-prototype/build/outputs/aar/android-airplay-foundation-debug.aar`. Run native
build before AAR packaging; the Gradle preBuild guard rejects missing native libraries.
Build and test evidence belongs in ignored `artifacts/android/`.
If offline Gradle lacks its matching Maven aapt2 binary, pass
`-Pandroid.aapt2FromMavenOverride="$ANDROID_HOME/build-tools/36.0.0/aapt2"`
to use the already installed build-tools executable. The completed diagnostic
APK build used this option; no additional SDK component was installed.

Host tests require loopback socket permission. They create an unadvertised,
temporary UxPlay listener and send only synthetic HTTP/RTSP input. No existing
receiver process, port configuration or network security setting is modified.
Optional memory checks can be run by configuring the same CMake source with
`-DHOST_SANITIZE=ON` in a separate build directory.

## Exact completed validation (2026-10-03)

- Android CLI 1.0.16406183 read-only environment and official documentation
  queries succeeded. Installed SDK platforms span 28–37; NDKs 26.3, 27.0,
  27.3 and 28.2 are present. Existing license files were observed; the builds
  succeeded without accepting or changing licenses.
- NDK 28.2.13676358 / Clang 19.0.1 cross-compiled OpenSSL 3.6.4, libplist 2.6.0,
  locked UxPlay core and JNI for arm64-v8a and x86_64, Android API 26.
- Host synthetic tests passed: original TXT entry replacement, invalid key
  rejection, actual core `/info` binary-plist response and `OPTIONS`, three
  start/stop cycles, duplicate-start/invalid-name handling, idempotent stop,
  bounded queue overflow and visible epoch resets.
- The same native synthetic test passed AddressSanitizer and UBSan on macOS
  with no reported diagnostic. Host OpenSSL was uninstrumented; this is not an
  exhaustive network-input sanitizer run or Android instrumentation test.
- A separate ASan/UBSan fixture in the listener-denied sandbox passed three
  actual bind-failure/partial-startup cleanup/retry cycles. The source-preparation
  script now checks the lifetime and RTP epoch patch markers explicitly; final
  host, sanitizer, Android builds and device checks used the patched core.
- Java synthetic TXT parsing passed binary-value preservation, truncated-record
  rejection and empty-key rejection.
- Gradle 9.3.1, AGP 9.1.0, existing JBR 25.0.3 and SDK 36 compiled the Java NSD/JNI
  boundary. Final AAR packaging passed with both native ABIs and all six
  license/notice assets; Android lint reported no issues. Package inspection
  verified ELF load-segment alignment of 16 KiB and the five expected JNI names.
  These static checks do not prove runtime loading or 16 KiB-device compatibility.
- Initially adb showed no targets; two existing AVD definitions were listed and
  neither was started. The user then connected one physical 23127PN0CC / houji
  target, Android 16 / API 36, arm64-v8a, 4 KiB page size.
- `AirPlay Core Validation` debug APK built and was installed on that target.
  Device instrumentation passed actual JNI library load, pairing-key generation
  in private cache and cleanup, actual core `/info` + `OPTIONS` over loopback,
  native TXT access, three native sessions, duplicate receiver rejection,
  idempotent close, empty poll/epoch access, and closed-state guards. Input was
  synthetic; the APK did not advertise Bonjour or render/play media.
- Diagnostic APK lint had no errors; its deliberate targetSdk 36 carries one
  OldTargetApi warning. The AAR's own lint reported no issues.

No Android NSD callback, LAN discoverability, pairing from an
iPhone, media reception, MediaCodec decode, visible image, AudioTrack output,
A/V synchronization, orientation change or Android-device support has been
validated. Host tests exercise native protocol responses and synthetic queues;
they do not validate encrypted RTP or actual media callbacks from a sender.
No macOS or Flutter regression result is inferred from these checks.

## Next implementation sequence

1. Extend the delivered diagnostic APK. JNI load and repeated ownership passed
   on API 36; still verify API 26 minimum, bind failure, persisted app identity
   and long-lived private keys, NSD success/failure/late callbacks and LAN
   permission denial. Keep advertised features off until playback exists.
2. Extend the native media boundary with `audio_get_format`, video size/codec
   changes, pause/resume, volume, connection and reset events. Current polling
   carries data/clock/epoch only; audio codec-specific configuration and visible
   session state are incomplete. Reject unsupported capabilities explicitly.
3. Implement AVC MediaCodec input/config parsing and output to a Surface on a
   dedicated decode thread. Add HEVC only after querying actual codec capability.
   Use a Flutter texture SurfaceProducer when integrated; retain a standalone
   Android SurfaceView harness for debugging. Recreate/flush decoder on format,
   rotation, epoch and Surface lifecycle changes.
4. Implement AAC-LC/AAC-ELD capability checks and AudioTrack PCM output with a
   separate bounded audio queue. ALAC requires a separately licensed software
   decoder; the reference uses FFmpeg. Do not advertise all upstream `cn` codecs
   while these decoders are missing. Current upstream TXT codec/feature flags
   are protocol defaults, not proof of implemented Android playback capability.
5. Map the core's Unix/NTP nanoseconds to Android monotonic playback time with a
   shared session anchor; measure AudioTrack playback timestamps and schedule
   video against audio. Never pass wall-clock values directly to timed Surface
   release APIs or mix nanoseconds and MediaCodec presentation microseconds.
6. Add a foreground receiver service and explicit activity/Flutter engine
   lifecycle policy. Define power, Wi-Fi/network change and background behavior;
   handle resource teardown and late registration callbacks on cancellation.
7. Run real iPhone acceptance: discovery, pairing, video, sound, lip sync,
   rotation, reconnect, repeated sessions and sustained playback. Keep exact
   OS/device/codec/latency measurements separate from synthetic test results.

## Minimal shared Flutter contract proposal

Keep `org.airplayreceiver/control` / `org.airplayreceiver/events` and existing
`snapshot`, `save`, `start`, `stop`, `check` method names. Android stores its native
settings in app-private preferences; it does not need an external UxPlay path.
Add capability fields (`receiveCore`, `videoDecode`, `audioDecode`, `texture`,
supported codecs) and distinguish native-bound, discovering, ready, receiving
and visibly-rendering states. `check` should report missing playback support
until it is implemented; starting a listener alone must not show successful
playback. Only texture ID, dimensions, bounded diagnostics and state cross Dart
channels; media stays native. The shared Dart owner should make these changes
sequentially after reviewing the Android bridge.

Generate the Flutter Android scaffold in another temporary project and merge
only its Android subtree after the channel contract is accepted. Do not run
`flutter create` blindly over the macOS WIP. The standalone prototype's AGP 9
build must not force an unreviewed Flutter Gradle upgrade.

## Sources and attribution

Architecture research used the pinned GPL reference in
`android-prototype/NOTICE.md`. Official sources consulted:
[Android NSD](https://developer.android.com/develop/connectivity/wifi/use-nsd),
[MediaCodec](https://developer.android.com/reference/android/media/MediaCodec),
[AudioTrack](https://developer.android.com/reference/android/media/AudioTrack),
[AGP 9.1 compatibility](https://developer.android.com/build/releases/agp-9-1-0-release-notes),
and [local network permissions](https://developer.android.com/privacy-and-security/local-network-permission).
At review time, the LAN documentation requires broad `ACCESS_LOCAL_NETWORK`
runtime handling for apps targeting SDK 37+, while SDK 36 and lower use their
existing INTERNET permission behavior. The final application owner must choose
and test its targetSdk and denial handling; this library never prompts for or
changes permissions on the machine.
