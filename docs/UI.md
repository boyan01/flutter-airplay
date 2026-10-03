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

## Completed integration validation

On 2026-10-03 the final root application passes `flutter analyze` and all 15
Flutter tests, including explicit Select-center and Enter/D-pad activation,
settings cancellation, layered Back, focus restoration and synthetic aspect
changes. Both platform release builds completed. Native synthetic lifecycle,
frames, audio, sync, RTP and recovery suites passed.

macOS CUA verified the new visible interface, cancelled name draft, window zoom
resizing, native fullscreen/Escape, embedded expanded preview/Escape and receiver
ready. The final signed 0.1.2+3 application is running from this project.

An incremental Xcode signing defect was reproduced: the outer app's sealed
`App.framework` CDHash remained from the previous Dart build while the inner
framework was valid. The embed phase now declares its generated framework
outputs so Xcode refreshes the outer signature. Two subsequent Dart-only
rebuilds (temporary title change and restoration) passed
`codesign --verify --deep --strict`. This uses the existing local ad-hoc signing
flow; it is not Developer ID signing or notarization.

Android's shared-UI release APK was source-built, signature checked and updated
on the connected Xiaomi 14 with matching signing certificate and retained data.
Six Kotlin state-adapter tests pass through Gradle. Phone D-pad Select/Enter,
start/stop/restart, log Back/focus restoration and immersive preview/Back were
observed. TV capability layout and focus are covered by Flutter tests; no
physical TV acceptance is claimed.

See [SHARED_UI_VALIDATION.md](SHARED_UI_VALIDATION.md) for exact artifact and
command evidence. These checks do not establish new-build real iPhone image,
audible sound, A/V synchronization, rotation/reconnect or sustained playback.
Runtime logs, screenshots, APKs and dependency caches remain ignored. macOS
continues to require local Homebrew dependencies; playback remains embedded.
