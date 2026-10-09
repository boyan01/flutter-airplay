# Flutter AirPlay

## Application structure

One Flutter application serves macOS, Android phones/TV, iPad, Windows and Linux,
with `lib/main.dart` as its entry point. Platform support and runtime limitations
are described in [README.md](README.md); iPad, Windows and Linux are experimental.

- `lib/ui/`: shared screens, widgets, layout and input handling.
- `lib/receiver/receiver_model.dart`: shared receiver state and application actions.
- `lib/receiver/receiver_repository.dart`: receiver control and event contract with
  native hosts. Extend this contract consistently across hosts when needed.
- `lib/app/`: app widget, theme and logging; `main.dart` initializes dependencies.
- `lib/receiver/native/`: FFI transport and JSON/C conversion; generated bindings
  live in its `generated/` directory. UI/model consume typed state and settings.
- `lib/platform/window_controller.dart`: window/system commands and host events.
- `native/include/airplay/`: public C host/player headers; `receiver_ffi.h` adds
  the Dart adapter contract. Host runners do not inherit private include roots.
- `native/receiver/`: receiver state, desired/active settings and serial lifecycle.
  Its copied event outlet has no Dart SDK or transport dependency.
- `native/protocol/`: UxPlay callback conversion, connections and discovery records.
- `native/playback/`: shared media queues, timing, decode scheduling and recovery.
- `native/backends/`: platform codec/output adapters and shared FFmpeg support.
- `native/tests/`: shared receiver, FFI, protocol, playback and media fixtures.
  Real host/device/window tests live in their platform projects.
- Platform hosts: discovery, video surfaces, windows and OS lifecycle. Apple
  hosts share `native/apple/`; codecs and audio devices belong in backends.
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

## Release preparation

When asked to prepare or publish a new version, generate its changelog as part of
updating `pubspec.yaml`; the user does not need to supply release notes manually.
Use [DEVELOPMENT.md](DEVELOPMENT.md) for release commands and prerequisites.

- Use `CHANGELOG.md` as the source of user-facing version history. Create it on
  the first release preparation if absent. Keep newest versions first, using
  `## MAJOR.MINOR.PATCH`, followed by `### 中文` and `### English` bullet lists.
  Preserve existing entries; do not invent historical notes to fill the file.
- Establish the previous published stable release and its tag commit, then
  inspect the commits and actual changes through the intended release commit.
  Include earlier unpublished work, not just the current conversation. If the
  baseline cannot be verified, report the gap rather than guessing.
- Write concise, equivalent Chinese and English notes about features, useful
  improvements and important fixes. Usually 3–6 bullets are enough; scale to the
  release. Name affected platforms and any required user action or changed
  limitation. Omit routine refactors, CI changes and raw commit lists unless
  they affect users. Do not claim support or verification beyond the evidence.
- Update `version: MAJOR.MINOR.PATCH+BUILD` and its changelog entry together.
  Both the semantic version and build number must exceed every published stable
  release. The tag must be `vMAJOR.MINOR.PATCH` and reference the commit containing
  both changes. Do not change the version for ordinary development or local
  packaging unless requested.
- The publishing script reads the version entry for GitHub Release notes and
  the in-app update feed. Keep generated installation/platform notices separate
  from the changelog. Use simple text bullets with optional indented continuation
  lines; avoid nested lists, raw HTML and additional subheadings. Both languages
  are embedded in the feed and shown together in the current update panel.
  Formal releases require a matching, unique entry with both languages.
- Before publishing, verify the version, changelog, tag and relevant checks.
  Report actual coverage and any unavailable checks. Preparing notes or a
  version does not by itself authorize pushing a tag or publishing a Release;
  follow the user's existing authorization for those actions.

## Documentation

- `README.md`: product features, usage and runtime/platform limitations.
- `DEVELOPMENT.md`: environment, run/build/test/package commands and test scope.
- `AGENTS.md`: project-specific code boundaries and development conventions.
- `CHANGELOG.md`: bilingual user-facing version history, maintained during release preparation.
- License notices and `vendor/*/UPSTREAM.md`: third-party licensing and provenance.
- `assets/app_icon/README.md`: asset provenance and platform export details.

Update documentation only when a change affects its intended reader's actions or
decisions. Update `DEVELOPMENT.md` for changed development commands,
prerequisites or verification steps.

Update the existing authoritative document instead of adding platform READMEs
or another command guide. Keep per-task reports, logs, screenshots and device
identifiers in ignored `artifacts/`; generated products and caches belong in
ignored output directories.
