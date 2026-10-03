# Flutter AirPlay development

## Working conventions

- Reply in Chinese. Keep code, comments and commit messages in English; follow
  the existing language when editing documents.
- Explain the outcome first, using short, direct sentences. Distinguish current
  behavior, code dependencies and design requirements.
- Confirm that new logic is necessary before adding it. Prefer existing
  abstractions and keep the change small.
- Show an ASCII UI sketch when changing UI or UX.
- Keep commit messages, PR titles and branch names free of `[codex]` or `codex/`
  prefixes.
- In code reviews, include every actionable finding in selectable Markdown in
  the final response: priority, file and line, failure scenario, and safe remedy.
  Inline comments may supplement this list.

## Source and product boundaries

- Maintain one root Flutter application for macOS, Android phones and TV, with
  `lib/main.dart` as its entry point. Keep shared UI and receiver state in `lib/`;
  platform hosts own reception, rendering, audio and lifecycle.
- Maintain macOS playback inside the application. Do not add a standalone-window
  product mode or a Go component.
- Edit the shared receive core directly in `vendor/UxPlay/`. Both platforms build
  this source; preserve the receive/playback boundary and GPL notices. Record
  upstream updates in `vendor/UxPlay/UPSTREAM.md`.
- Keep generated build products in ignored output directories and local evidence
  in `artifacts/`. Keep logs, screenshots, binaries, credentials and device or
  network identifiers out of public source.

## Validation

Run checks that match the changed code. Shared receive-core changes require both
macOS and Android builds and the relevant native regressions. Rebuild the native
receiver/player before packaging an application that uses changed native code.
Documentation-only changes require link and diff checks; they do not require
application builds.

- Flutter: `flutter analyze` and `flutter test`.
- macOS build: `./scripts/build_receiver.sh`, then `flutter build macos`.
- macOS native regression: `./scripts/test_native.sh "$PWD/native/receiver/uxplay"`,
  `./scripts/test_frames.sh`, `./scripts/test_audio.sh`, `./scripts/test_sync.sh`,
  `./scripts/test_rtp.sh` and `./scripts/test_recovery.sh`.
- Android build: `./android/scripts/build_native.sh`, then
  `flutter build apk --release --target-platform android-arm64`.
- Android native regression: `./android/scripts/test_host.sh`; build prerequisites,
  OpenSSL selection and sanitizer commands are in `docs/ANDROID.md`.

Use synthetic inputs for native regression. Report the exact checks completed,
their input and remaining gaps. Synthetic results, build success and receiver
state events do not establish real iPhone image, audible sound, synchronization
or Android-device support. Tie results to the tested build and report them in the
final response and PR description when creating a PR.

## Task-specific references

- For build/run instructions and distribution limits, read `README.md`.
- Before changing shared UI or platform channels, read `docs/UI.md`; for Android
  state, capabilities and Back/focus behavior, also read `docs/ANDROID_UI.md`.
- Before changing Android native code or dependencies, read `docs/ANDROID.md`.
- When updating dependencies or preparing distribution, read
  `THIRD_PARTY_NOTICES.md` and preserve the bundled license assets.
