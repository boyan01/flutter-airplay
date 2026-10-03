# Shared Flutter receiver UI

The root Flutter project owns one application, receiver model and screen for
macOS, Android phones and Android TV. Platform hosts own receiving, rendering,
audio and lifecycle. The UI changes do not alter the media core, audio clock,
PTS recovery or GPL notices. macOS playback remains embedded in Flutter.

## Layout and interaction

The main screen puts the device name and current state above a large preview.
The primary button starts receiving, stops a waiting receiver, or stops an
active stream. Checking/starting/stopping operations show progress and reject
duplicate commands. Preparation, waiting, connected and error are separate
states; a connected device may still be waiting for its first video frame.

An empty preview explains how to connect through iPhone Control Center and
Screen Mirroring. Video preserves its reported aspect ratio in the available
space. Stop, disconnect and error clear the visible video dimensions.
Settings and logs open on demand. Settings use local draft fields: Cancel,
Escape or Android Back discard the draft, while Save validates and persists it.
Editing is disabled during reception. Errors preserve the native detail and
provide environment checking, settings, logs and retry actions.

Appearance offers system, light and dark themes. Compact screens stack the
primary action and scroll vertically. TV uses larger type and controls with a
visible focus border. Material directional navigation and Enter/Select activate
controls; initial focus is on the primary action. Returning from a dialog or
fullscreen restores that focus. Android Back first closes a dialog, then leaves
fullscreen, then follows the host's ordinary activity navigation. It does not
silently stop a stream while closing a dialog or fullscreen.

macOS shortcuts: Command-R starts/stops, Command-F enters/leaves fullscreen,
Command-comma opens settings, Command-L opens logs, and Escape leaves fullscreen.
Shortcuts cannot start/stop while a dialog is open. Native macOS fullscreen and
Flutter presentation state stay synchronized, including the window's green
fullscreen button. Android uses immersive system UI for expanded viewing.

## Platform contract

Both hosts expose `org.airplayreceiver/control` and
`org.airplayreceiver/events`. Commands are `snapshot`, `save`, `check`, `start`,
and `stop`. Settings contain `name` and `path`; unsupported paths remain empty.
Snapshots use `status`, `message`, `name`, optional `path`, diagnostic `pid`,
`textureId`, `videoWidth`, `videoHeight`, and bounded `logs`. State events use
`type: state`, `status`, `message`, optional `pid`; video events use `type: video`
and the texture/dimension fields. `snapshot` and `log` events retain the existing
macOS contract. The model determines active reception from status, never PID.

A snapshot may add:

```json
{
  "capabilities": {
    "platform": "android",
    "isTelevision": true,
    "supportsExecutablePath": false
  }
}
```

Capabilities control wording, TV input/layout and the advanced executable-path
setting. Old macOS snapshots remain supported; missing platform information
falls back to Flutter's target platform. Android screens do not mention
GStreamer or offer a macOS executable path. Platform-specific presentation stays
at the window/system-UI boundary; there is no second Android Dart screen.

## Validation for this checkpoint

Checkpoint validation (2026-10-03): `flutter analyze` reports no issues;
all 15 Flutter widget/model tests pass; `flutter build macos` produces a
47.4 MB Release application. The native receiver rebuild and existing
`test_native`, `test_audio`, `test_sync`, `test_rtp`, `test_recovery`, and
`test_frames` suites all pass. These suites use synthetic inputs and test-owned
processes/endpoints.

Local `codesign --verify --deep --strict` on this new application fails with
"nested code is modified or invalid". This remains an integration task before
switching the running application; successful compilation is not signature
verification or distribution signing.

Widget tests use fake repositories and synthetic video metadata. They check shared state,
settings cancellation, operation deduplication, error recovery, phone/TV
capabilities, D-pad Enter and Back with focus restoration, aspect changes,
stopping, dark/light themes and small/large-text layouts.

The old macOS application was observed but was not stopped or switched during
this checkpoint. Visible acceptance of the new UI, native fullscreen/Escape,
window resizing and visible texture output remains for the integration owner.
No new-build CUA acceptance is claimed. Synthetic validation does not establish
real iPhone image, audible sound,
A/V synchronization, sustained playback, or Android/TV device support. The
Android host integration and its actual device acceptance belong to the Android
owner. Runtime logs and screenshots must remain in ignored `artifacts/`, never
in public source. Homebrew dependencies and local signing remain the existing
macOS development constraints.
