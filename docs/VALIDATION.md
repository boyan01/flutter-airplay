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

This baseline uses an independent GStreamer video window and Homebrew runtime
libraries. Embedded video and Android validation will be recorded as implemented.
