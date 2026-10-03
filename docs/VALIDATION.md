# Validation

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
