# Android native build and regression

The root `android/` host is the only maintained Android application. It shares
root `lib/main.dart` with macOS. The former `android-player/` and
`android-prototype/` projects were retired; their history remains in Git.

## Maintained sources

- `android/app/src/main/cpp/`: JNI player, audio engine and DNS/TXT storage adapter.
- `android/app/src/main/cpp/ReceiverCore.cmake`: receive-core build shared by
  the Android product and synthetic host regression.
- `vendor/UxPlay/`: maintained receive core, including shared lifetime fixes.
- `android/dependencies.lock.json`: pinned OpenSSL, libplist, Oboe, FFmpeg and
  reference-source provenance.
- `android/tests/`: synthetic native receiver fixture. Its lifecycle fixture is
  test support, not the product's JNI host.

Both platforms compile `vendor/UxPlay` directly. Upstream version and base
commit are recorded in `vendor/UxPlay/UPSTREAM.md`; local modifications are
tracked in project Git. The receive/playback boundary and GPL
notices remain in place. See `android/NOTICE`, `android/CORE_NOTICE.md`,
`android/COPYING` and the APK's bundled license assets.

## Build

From repository root on macOS with an existing Flutter SDK, Android SDK,
NDK 28.2.13676358 and CMake 3.22.1:

```sh
ANDROID_HOME="$HOME/Library/Android/sdk" ./android/scripts/build_native.sh
flutter build apk --release --target-platform android-arm64
```

The native command fetches and verifies pinned dependency sources, builds
static OpenSSL when missing, then builds and strips
`android/app/src/main/jniLibs/arm64-v8a/libairplay_player.so`. Dependency sources
and OpenSSL builds live in ignored `android/.cache/`; native player output lives
in ignored `build/android-native-arm64/`. No standalone AAR is built.
The current product packages only arm64-v8a.

## Synthetic host regression

With CMake and a native OpenSSL installation:

```sh
HOST_CRYPTO_PREFIX="$(brew --prefix openssl@3)" ./android/scripts/test_host.sh
HOST_CRYPTO_PREFIX="$(brew --prefix openssl@3)" HOST_SANITIZE=ON ./android/scripts/test_host.sh
```

This compiles the same maintained receive core and DNS/TXT adapter as the product.
The retained fixture checks TXT replacement, `/info`, `OPTIONS`, three
start/stop cycles, duplicate start, partial initialization and DNS object
lifetime. The retired prototype media queue and its tests have been removed.
Logs go to ignored `artifacts/android/`. These inputs are synthetic and do not
prove actual sender playback or Android-device support. The former Java JNI
wrapper, AAR packaging checks and diagnostic device harness were removed.
Current application/device evidence is recorded separately in
[ANDROID_UI.md](ANDROID_UI.md), [ANDROID_PLAYER.md](ANDROID_PLAYER.md) and
[SHARED_UI_VALIDATION.md](SHARED_UI_VALIDATION.md).

## Historical directory consolidation validation (2026-10-03)

- `./android/scripts/build_native.sh`: rebuilt OpenSSL and the arm64 player in
  the new cache/build paths, without the retired foundation directory.
- `./android/scripts/test_host.sh`: native synthetic regression passed normally
  and with ASan/UBSan; no sanitizer diagnostics were reported. Host OpenSSL was
  uninstrumented.
- `flutter analyze`: no issues; `flutter test`: 15 tests passed.
- `:app:testDebugUnitTest -Ptarget-platform=android-arm64`: six tests passed,
  zero skips/failures/errors.
- `flutter build apk --release --target-platform android-arm64`: succeeded.
  Package inspection confirmed the APK contains the exact rebuilt native library
  and all nine existing license assets.
- Moved DNS/TXT source, regression fixtures, lifetime patch and GPL text match
  their pre-migration content. Vendored UxPlay hashes still match its lock.

APK SHA-256: `584c80bf4162efbbbd12dbb694119a34827270cf0cd951d1af43eef72e653e1f`.
Logs are in ignored `artifacts/android/consolidation-*.log`. This cleanup did
not install the APK or perform new physical-device/iPhone playback checks.
Build tools reported existing Kotlin-version and Gradle-deprecation warnings;
both packaging and unit tests succeeded.

## Historical foundation validation (2026-10-03)

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
  script checks the lifetime and RTP epoch patch markers explicitly; final
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

At this foundation-only checkpoint, no Android NSD callback, LAN discoverability, pairing from an
iPhone, media reception, MediaCodec decode, visible image, AudioTrack output,
A/V synchronization, orientation change or Android-device support has been
validated. Host tests exercise native protocol responses and synthetic queues;
they do not validate encrypted RTP or actual media callbacks from a sender.
No macOS or Flutter regression result is inferred from these checks.
