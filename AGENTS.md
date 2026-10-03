# Flutter AirPlay development

- Edit the maintained UxPlay source directly in `vendor/UxPlay`; keep build
  outputs under ignored `build/`. Record upstream updates in
  `vendor/UxPlay/UPSTREAM.md` and validate both macOS and Android.
- Preserve GPL notices and the receive/playback boundary. No Go component.
- Native build: `./scripts/build_receiver.sh`; Flutter: `flutter analyze`,
  `flutter test`, `flutter build macos`.
- Native regression suite: `./scripts/test_native.sh "$PWD/native/receiver/uxplay"`,
  `./scripts/test_audio.sh`, `./scripts/test_sync.sh`, `./scripts/test_rtp.sh`,
  `./scripts/test_recovery.sh`. Use synthetic inputs; logs go in ignored `artifacts/`.
- Do not claim real iPhone image, sound, synchronization or Android device support
  from a synthetic test. Record the exact completed validation scope.
- Maintain only embedded macOS playback; do not add a standalone-window product mode.
