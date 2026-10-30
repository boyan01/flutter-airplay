# Flutter AirPlay

One Flutter/C++ application serves macOS, Android phones/TV, iPad, Windows and Linux.
Extend the existing model, repository and native core. Decoding, audio output and A/V timing belong to
the lychee_player pub package; fix playback there rather than adding a player here.

## References

- [README.md](README.md) and [README_ZH.md](README_ZH.md): product usage and platform support. Keep both versions aligned.
- [DEVELOPMENT.md](DEVELOPMENT.md): read when setting up, running, testing or packaging.
- [CHANGELOG.md](CHANGELOG.md): user-facing version history.

## Code boundaries

| Area | Responsibility |
| --- | --- |
| `lib/ui/`, `lib/app/` | Shared widgets, input, theme and app setup |
| `lib/receiver/` | Receiver state, actions, settings persistence and repository contract |
| `lib/receiver/native/`, `native/ffi/` | FFI transport, JSON conversion and Dart subscriptions |
| `native/receiver/` | Receiver state, desired/active settings and serial lifecycle |
| `native/protocol/` | UxPlay callbacks, connections and discovery records |
| `native/playback/` | Adapter from UxPlay's streams to the lychee_player live C ABI, and frame hand-off to hosts |
| `native/backends/windows/` | Windows DNS-SD and video frame descriptors |
| `lib/platform/`, platform hosts | Window control, discovery, video surfaces and OS lifecycle; Apple hosts share `native/apple/` |

Widgets use typed model state and own presentation and transient UI state.
Keep receiver behavior in the shared model/core and OS integration in platform adapters.
Host runners use public headers in `native/include/airplay/`; the receiver core exposes copied events,
with Dart transport owned by `native/ffi/`.

Edit `vendor/UxPlay/` directly when changing protocol behavior. Preserve GPL notices and record
upstream changes in `vendor/UxPlay/UPSTREAM.md`.

## Cross-platform changes

- Implement shared feature changes across applicable platforms, including experimental hosts.
  Check each adapter when changing commands, snapshots, events or settings.
- Express platform capability differences in shared state and UI. Propagate native failures into
  receiver state and preserve cleanup and recovery across stop, reconnect and lifecycle changes.

## UI

- Reuse shared pages and widgets. Adapt layout to available space with `LayoutBuilder` and
  `MediaQuery.sizeOf`; cover resizing, safe areas, the keyboard and larger text.
- Use `lib/app/app_theme.dart` for shared styles. Preserve system light/dark appearance and the TV dark theme.
- Support touch, mouse and keyboard. Reuse `lib/ui/tv_focus.dart` for visible TV focus, D-pad navigation
  and Back behavior. Restore focus after dialogs and playback transitions; keep essential actions reachable.
- Add user-facing strings to both `lib/l10n/app_en.arb` and `app_zh.arb`, using `AppLocalizations`.
  Keep native diagnostic text intact. Generation commands are in DEVELOPMENT.md.
- Keep receiver side effects in actions and lifecycle handlers. Dispose owned subscriptions,
  timers and focus nodes; check `mounted` after asynchronous work before updating UI.

## Verification

Choose verification scoped to the change, reusing passing results while their inputs remain valid.
Dart tests use `flutter test`; native tests use `scripts/test_native.sh`.
Prefer Flutter unit and widget tests for UI layout, interactions, focus, timers, edge cases and state combinations.
For changes fully covered by these tests, verification is complete when scoped tests and static checks pass.
Use `flutter run` when the affected behavior requires a real host, window or device to verify.
Exercise that behavior; startup or hot reload alone does not verify it.
Keep desktop integration coverage to one main-flow test per platform, running in one application instance.
Extend that shared flow only for essential end-to-end behavior.
Keep the default native suite small and select device/codec matrices explicitly.
Add fixtures to the relevant suite, with generators beside their test sources.
Shared native tests live in `native/tests/`; real host, window and device tests live in platform projects.
Report checks performed and platform/device coverage. Use CI results for the submitted revision.

## Commits

Write commit messages for someone scanning `git log`:

- Subject: one imperative line under 72 characters naming the result, e.g. `Build every host from Flutter`.
- Body only when the subject needs it: at most about five short lines or bullets on why, and on
  changes a developer must act on (new requirements, removed scripts, migration steps).
- Leave out file inventories, implementation walkthroughs, verification results and evidence paths;
  report those in the task response.

## Releases

When preparing a release, verify the previous published stable tag and inspect the changes
since it, including earlier unpublished work. Update `pubspec.yaml` and `CHANGELOG.md` together.
Each version has one `## MAJOR.MINOR.PATCH` entry, with exactly one `### 中文` and one
`### English` section, each containing nonempty `- ` bullets. The release/update pipeline
parses this structure; the writing rules below apply to the bullet text.
Use DEVELOPMENT.md for release steps.

Write release notes for users deciding whether to update:

- Select the changes with the clearest user benefit, most useful first. Prefer 1–3 short bullets
  per language, scaling to the release.
- Give each bullet one short sentence about a new capability or a concrete problem fixed.
  Combine related changes into one user-visible result.
- Name platforms for platform-specific changes and include required upgrade steps.
  Keep engineering details and verification coverage in the task response.
- Keep Chinese and English equivalent in meaning and brevity.

Example: `新增视频裁剪。` / `Added video cropping.`

## Documentation

Keep each topic in its authoritative document. Document behavior that changes a reader's actions
or decisions; use source code and script help for implementation details and option inventories.
Keep task logs, screenshots and reports in ignored `artifacts/`.
