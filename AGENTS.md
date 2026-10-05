# Flutter AirPlay

## Application structure

One Flutter application serves macOS, Android phones/TV, iPad, Windows and Linux,
with `lib/main.dart` as its entry point. Platform support and runtime limitations
are described in [README.md](README.md); iPad, Windows and Linux are experimental.

- `lib/ui/`: shared screens, widgets, layout and input handling.
- `lib/receiver/receiver_model.dart`: shared receiver state and application actions.
- `lib/receiver/receiver_repository.dart`: receiver control and event contract with
  native hosts. Extend this contract consistently across hosts when needed.
- `native/player/`: shared C++ playback, timing and receiver lifecycle.
- Platform hosts: discovery, codecs/output, video surfaces, windows and OS lifecycle.
- `vendor/UxPlay/`: shared receive protocol core. Edit it directly, preserve GPL
  notices and record upstream updates in `vendor/UxPlay/UPSTREAM.md`.

Extend these existing boundaries. Keep receiver behavior in the shared model/core;
widgets own presentation and transient UI state. Keep OS integration in the host
or its adapter. Introduce a new layer or state-management package only when the
existing structure cannot reasonably support the feature.

Playback stays inside the application. Preserve the receive/playback boundary;
keep this a Flutter/C++ product without a separate player application or Go service.

## Cross-platform development

- Implement a new or changed feature across all applicable platforms in the same
  task, including experimental hosts. Share its state, settings, validation and
  user-visible behavior; check platform adapters for missing implementations.
- Platform capability and lifecycle constraints can require different behavior
  (for example, iPad foreground reception or desktop tray integration). Make
  unsupported actions explicit and explain any feature gap. An existing missing
  implementation is not a reason to skip a platform.
- Keep native commands, snapshots and events consistent with the Dart contract.
  Propagate failures into receiver state so every UI can show them. Preserve
  cleanup and recovery when stopping, reconnecting or changing app lifecycle.

## Flutter UI

- Reuse shared pages and widgets across targets. Keep terminology, settings,
  status/error states and action outcomes consistent. Adapt presentation and
  input to the target without creating independent copies of the same feature.
- Base responsive layout on available space: use `LayoutBuilder` for local
  constraints and `MediaQuery.sizeOf` for the app window. Platform identity alone
  does not determine layout. Handle resizing, portrait/landscape, safe areas,
  the on-screen keyboard and larger text without clipping controls.
- Reuse `ThemeData`, `ColorScheme`, text styles and component themes from
  `lib/main.dart`. Preserve system light/dark appearance and the TV dark theme.
  Add shared styles where repeated values need to stay consistent.
- Support touch, mouse and keyboard. TV controls need visible focus, D-pad access,
  activation and predictable Back behavior. Reuse `lib/ui/tv_focus.dart`; restore
  useful focus after dialogs, navigation and playback transitions. Essential
  actions must remain available without hover or touch.
- Add user-facing strings to both `lib/l10n/app_en.arb` and `app_zh.arb`, consume
  `AppLocalizations`, and regenerate with `flutter gen-l10n`. Edit ARB sources
  rather than generated localization classes. Keep native diagnostic text intact.
- Keep rendering free of receiver side effects. Dispose owned subscriptions,
  timers and focus nodes; guard UI updates after asynchronous work with `mounted`.

For layout changes, consult Flutter's [adaptive design guide](https://docs.flutter.dev/ui/adaptive-responsive).
For changes to state or layer boundaries, consult the [architecture guide](https://docs.flutter.dev/app-architecture/guide)
and apply it to the existing model/repository structure rather than restructuring
unrelated code.

## Development workflow

Use [DEVELOPMENT.md](DEVELOPMENT.md) when setting up a host, running the app,
selecting tests or packaging. It is the single reference for commands and their
prerequisites across platforms.

Use `flutter test` for Dart tests and `scripts/test_native.sh` for native tests.
Extend the relevant suite in that entry point instead of adding a test runner
per fixture or platform. Keep the default suite small and select extended host,
codec or device matrices explicitly. Run a shared fixture once per build
configuration; retain platform backend and recovery coverage. Keep fixture
generators with their test sources.

Prefer the `flutter run` development loop and checks scoped to the change.
Validate at useful checkpoints; reuse passing results while relevant inputs are
unchanged. Report actual coverage and unavailable targets. Delegate checks to CI
only when configured jobs cover the submitted revision.

## Documentation

- `README.md`: product features, usage and runtime/platform limitations.
- `DEVELOPMENT.md`: environment, run/build/test/package commands and test scope.
- `AGENTS.md`: project-specific code boundaries and development conventions.
- License notices and `vendor/*/UPSTREAM.md`: third-party licensing and provenance.
- `assets/app_icon/README.md`: asset provenance and platform export details.

Update the existing authoritative document instead of adding platform READMEs
or another command guide. Keep per-task reports, logs, screenshots and device
identifiers in ignored `artifacts/`; generated products and caches belong in
ignored output directories.
