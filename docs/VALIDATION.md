# Validation

## Unused-code cleanup (2026-10-03)

Removed the Android TV banner generator while retaining the packaged PNG,
unconsumed audio debug snapshots/latency counters, the unused LogSink JNI bridge,
video benchmark statistics and unused renderer methods, unreachable Android
HEVC selection/rendering, inactive product sanitizer flags, prototype-only media
queue tests, the empty macOS XCTest target and write-only receiver-name state.
Audio adaptive buffering, codec retry/software fallback, presentation scheduling,
error logs and actual receive-core lifecycle regressions remain.

Completed validation:

- Android native library rebuild and arm64 Release APK packaging succeeded.
- Compiled Kotlin `onVideoData` descriptor matches the native JNI lookup:
  `([BJ)V`. APK inspection verified the rebuilt native library and all nine
  license assets.
- Six Android state tests passed with zero failures/errors/skips.
- Native host receive-core regression passed under ASan/UBSan, including TXT,
  `/info`, `OPTIONS`, three receiver lifecycles and partial/DNS lifetime cases.
- macOS project plist validation, Release app build, native lifecycle and
  synthetic frame/texture regressions passed. The empty XCTest target and all
  associated project/scheme references were removed.
- `flutter analyze` reported no issues; all 15 Flutter tests passed.
- `git diff --check` passed; removed APIs and template targets have no remaining
  application references.

APK SHA-256: `0460450a3b1fba6182136ccccd55fe182e9f5b9329296bb00e39413c3d045dc2`.
Logs are in ignored `artifacts/cleanup-*.log`. No new physical Android/iPhone
playback, decoder fallback or audio acceptance was performed.


## Maintained UxPlay source migration (2026-10-03)

macOS and Android now compile the maintained `vendor/UxPlay/` source directly.
The previous integration/frame-output/lifetime patches were folded into this
source; patch application scripts and the per-file upstream hash lock were
removed. Upstream base v1.73.7 and commit are recorded in
`vendor/UxPlay/UPSTREAM.md`. Original license and copyright notices remain.

Completed validation:

- macOS native receiver build succeeded from `vendor/UxPlay/` into a fresh
  `build/uxplay-native/` tree.
- Android arm64 player rebuilt against the same receive-core source.
- Native lifecycle, audio, sync, RTP and recovery suites passed with synthetic
  inputs. Three real macOS helper ready/stop cycles passed.
- Frame transport and Flutter texture synthetic suites passed.
- Host receive-core regression passed under ASan/UBSan, including destruction
  before HTTP initialization, DNS unregister/re-register, and destruction before
  registration. Host OpenSSL was uninstrumented.
- `flutter analyze` reported no issues; all 15 Flutter tests passed.
- `flutter build macos` and arm64 Release APK build succeeded. Both packaged
  receivers matched the newly built native files; the APK retained nine license
  assets.
- No old generated UxPlay source tree remains, and current build/test scripts
  contain no references to the retired patch preparation or hash lock.

APK SHA-256: `c5275a13a5ac981bceff4dd937867bffff96aab0576f602e41fae6cc29225c36`.
Logs are in ignored `artifacts/uxplay-source-*.log`. No APK installation or new
physical-device/iPhone playback acceptance was performed. Existing build-tool
warnings about Kotlin compatibility and macOS architecture remain separate.

The sections below record earlier checkpoints.


The macOS prototype has user-confirmed iPhone image and audible playback.
After restoring timestamp synchronization and fixing stale RTP epochs, the
user reported the latest recovery build appeared normal. Long-duration,
rotation and repeated application-switch acceptance remain separate checks.

Development baseline: Flutter 3.47.2 / Dart 3.13.2, Apple Silicon macOS 27,
Xcode 27, GStreamer 1.28.7 and UxPlay v1.73.7. Local evidence is intentionally
excluded from the public repository.

- Flutter analyze: clean; widget/model tests: 7 passed in the prototype.
- Native lifecycle: missing dependencies, idempotent commands, process cleanup
  and three actual UxPlay ready/stop cycles passed.
- Synthetic ALAC decode, gain preservation, bad PTS rejection, same-codec SETUP
  and FLUSH recovery passed.
- Real loopback RTP stop/start clears old synchronization anchors in three cycles.
- Synthetic real-renderer shared-clock scheduling over 9.6 seconds and a fresh
  portrait session passed; recovery version max handoff skew 8.820 / 5.760 ms.
- macOS Release build and local signature verification passed.

The accepted prototype baseline uses an independent GStreamer video window and
Homebrew runtime libraries. Its user acceptance does not transfer to a new build.

## macOS embedded checkpoint (2026-10-03)

- Native receiver build, Flutter analyze, 9 widget/model tests, macOS Release
  (46.8 MB) and local `codesign --verify --deep --strict` passed.
- All required native lifecycle, audio, shared-clock, RTP and recovery suites passed.
  Synthetic shared-clock max handoff skew: 4.857 ms landscape / 3.785 ms portrait.
  This is fakesink handoff timing, not visible/speaker A/V latency.
- Frame tests pass actual UxPlay H264 parser/software decoder/BGRA appsink output,
  portrait/landscape renderer restarts, three socket lifecycles, malformed versions,
  dimensions, stride, length and reserved words, truncated headers/payloads,
  partial-frame invalidation/reconnect, stop during payload and a slow 1080p reader.
  The sender retains one in-flight and one replaceable pending frame.
- The actual FrameTexture implementation passes IOSurface CVPixelBuffer/BGRA pixel
  checks, deferred registration, coalesced notification across clear/restart,
  exactly-once unregister and disposed-engine rejection using a test-only registry.
  This fixture alone does not exercise Flutter rasterization.
- CUA inspected the Release application and confirmed visible synthetic red frames
  in FlutterTexture, aspect-preserving landscape/portrait changes (including actual
  UxPlay renderer output), expanded preview, macOS native fullscreen and Esc return.
  A black first attempt exposed registration before engine startup; the fixed build
  registers on the first Dart channel request and passed the visible checks.
- CUA checked stop-to-placeholder, embedded restart, Cmd-Q, and closing an active main window.
  The final product removes the previous standalone option and presentation setting;
  native lifecycle tests inject a test output and start the real appsink path.
  Owned child PIDs and sockets were checked after exit. The old recovery app was
  closed, its historical bundle retained, and the new embedded application left ready.
- A real iPhone connected to the new application and produced streaming/video/audio
  decode events; IPv6 NTP `No route to host` diagnostics were also observed. No real
  image, audible output, synchronization, long playback or repeated-device acceptance
  is claimed until the user confirms it. All synthetic producers were stopped before
  the final ready/reconnect notification.

No runtime logs, network/device identifiers, screenshots, binaries or private machine
paths are included in this public checkpoint. Evidence stays in ignored `artifacts/`.
The application now uses `org.flutterairplay.receiver` to keep LaunchServices and
preferences separate from the retained prototype. Homebrew remains required; local
signature verification is not Developer ID signing/notarization. Android is separate
work and is not validated or integrated by this macOS checkpoint.

## Main branch Android integration (2026-10-03)

`main` fast-forwards from `ff019a9d5f66aec45c24d259c4916fd4f5783d4e` to
`e1652886b3473031c6caa8a2f9fb6e567ef2710b`, which already contains the macOS
checkpoint. The feature branch adds only the two independent Android projects
and their documents. The macOS, root Dart/test, native patch, vendor and root
build files are identical to the macOS baseline. Follow-up changes clarify the
documentation and ignore the Android host's generated Kotlin cache.

Completed in an isolated checkout of the integrated source:

- Locked vendor verification and native macOS receiver rebuild passed.
- Root `flutter analyze` is clean; all 9 existing Flutter tests passed.
- Existing native lifecycle, audio, sync, RTP, recovery and frame/texture
  suites passed with synthetic inputs and test-owned processes/endpoints.
  Shared-clock maximum handoff skew was 11.080 ms landscape / 4.765 ms portrait;
  this measures synthetic sink handoffs, not visible or audible device latency.
- macOS Release build (46.8 MB) and `codesign --verify --deep --strict` passed.
- Android dependency sources matched their pinned commits and had no local
  changes before rebuilding. Foundation native libraries rebuilt for arm64-v8a
  and x86_64; the player native library rebuilt for arm64-v8a.
- Existing Android foundation host tests passed real-core synthetic `/info`
  and `OPTIONS`, 3 lifecycles, bounded queue/epoch resets and Java TXT parsing.
- Android foundation AAR and diagnostic APK builds passed. AAR lint found no
  issues; diagnostic APK lint had 0 errors and 2 warnings (`OldTargetApi` and
  `DataExtractionRules`). AAR inspection passed both ABIs, 16 KiB ELF load
  alignment, expected JNI names and six license/notice assets.
- Android player `flutter analyze`, arm64 Release APK build (including Gradle
  release lint-vital tasks) and APK signature verification passed. Package
  inspection confirmed arm64-only native libraries and nine license assets.
  It uses the existing local development signing setup, not distribution signing.

No application was installed, launched or restarted on a device for this
integration run, and the existing macOS application was left running.
The Android user's prior acceptance of discovery, connection, image and sound
is recorded in [ANDROID_PLAYER.md](ANDROID_PLAYER.md); synchronization,
rotation, reconnect and sustained stability remain separately unaccepted.
At that historical checkpoint, Android still used its separate `android-player/`
Flutter project; the shared-root migration below supersedes that arrangement.
Logs and generated products remain ignored under `artifacts/` and build/cache
directories and are not part of the public source commit.

The independent review remains incomplete: both prior attempts were blocked
by the platform and produced no usable review result. This integration run
performed ordinary branch integration, builds and existing functional regression
tests; it did not retry that review and does not claim review approval.

## Shared UI integration

The 0.1.2+3 root Mac/Android/TV UI build and device acceptance scope is recorded
in [SHARED_UI_VALIDATION.md](SHARED_UI_VALIDATION.md). Historical sender acceptance
above remains attributed to its original build.
