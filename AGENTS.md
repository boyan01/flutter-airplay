# Flutter AirPlay development

- Keep `vendor/UxPlay` pristine at `native/uxplay.lock.json`; edit generated
  `build/uxplay-src` and regenerate a patch in `native/patches`.
- Preserve GPL notices and the receive/playback boundary. No Go component.
- Native build: `./scripts/build_receiver.sh`; Flutter: `flutter analyze`,
  `flutter test`, `flutter build macos`.
- Native regression suite: `./scripts/test_native.sh "$PWD/native/receiver/uxplay"`,
  `./scripts/test_audio.sh`, `./scripts/test_sync.sh`, `./scripts/test_rtp.sh`,
  `./scripts/test_recovery.sh`. Use synthetic inputs; logs go in ignored `artifacts/`.
- Do not claim real iPhone image, sound, synchronization or Android device support
  from a synthetic test. Record the exact completed validation scope.
- Retain standalone macOS playback as a fallback while embedding evolves.
