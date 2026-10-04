# Linux host

Linux uses the root Flutter application (`lib/main.dart`) and the same C++
receiver, clock, bounded PCM queue and session lifecycle as the other platforms.
The GTK host embeds decoded video in a Flutter texture; it does not launch an
external player or subprocess.

AAC decoding shares `native/player/ffmpeg_audio_decoder.cpp` with Windows.
Both hosts use the same ALAC/AAC-LC/AAC-ELD PCM and recovery regression in
`native/player-tests/ffmpeg_audio_decoder_test.cpp`. Linux continues to link
distribution-provided FFmpeg libraries.

## Dependencies and build

Use the Flutter version pinned in `.fvmrc`. The software baseline requires
FFmpeg 6 or newer (`libavcodec >= 60`), GTK 3, PulseAudio or PipeWire's PulseAudio
compatibility server, Avahi, Ayatana AppIndicator 3, OpenSSL and libplist 2.3 or newer. Debian 13 is the
validated build environment; older distributions may need newer development
packages.

On Debian 13:

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
  libavcodec-dev libavutil-dev libswscale-dev libswresample-dev \
  libpulse-dev libavahi-client-dev libayatana-appindicator3-dev \
  libssl-dev libplist-dev libx11-dev libxi-dev
flutter pub get
flutter build linux --release
./build/linux/x64/release/bundle/flutter_airplay
```

The bundle includes the shared player library and tray icons. GTK, FFmpeg, PulseAudio, Avahi, Ayatana AppIndicator,
OpenSSL and libplist remain distribution-managed runtime dependencies. Ship the
whole bundle, including `data/` and `lib/`, and retain dependency license notices
when packaging. No FDK-AAC library is used or linked.

`avahi-daemon` must be running with access to the system D-Bus. The host only
reports readiness after both `_airplay._tcp` and `_raop._tcp` services have been
published. A missing daemon, inaccessible bus, duplicate name, or service loss
is shown as an error and tears down the listener. This application does not
start daemons, change firewall rules or set up a network tunnel.

Audio requires a usable PulseAudio-compatible output server. Failure to open
one is reported when an audio session starts. A silent/null sink is useful for
synthetic device tests but is not evidence of audible speaker output.

Settings, the random receiver identity and pairing key live in
`$XDG_CONFIG_HOME/flutter-airplay` (normally `~/.config/flutter-airplay`). Closing
the GTK window stops and joins receiver, playback and discovery workers before
unregistering the texture when exiting. Linux does not offer launch-at-login
integration or an external executable path.

## Desktop window and tray

The GTK window has no system title bar. The shared Flutter caption provides
dragging, minimize, maximize/restore and close; the edges and corners resize the
window. Caption dragging uses the `window_manager` Flutter plugin, including its
Linux pointer-state recovery after a native window move.
Mirroring changes the window to the decoded video's aspect ratio and
preserves its area on portrait/landscape changes. Leaving playback restores the
440 × 560 home window. Fullscreen and maximized windows defer automatic resizing
until restored. Wayland compositors control window placement and may restrict
background activation, aspect constraints and keeping a window above others.

The system tray uses Ayatana AppIndicator's StatusNotifierItem/DBusMenu support.
It requires a compatible desktop tray host (for example, KDE's system tray or
GNOME's AppIndicator extension). Its menu shows receiver state and offers the
existing receive/disconnect, window, settings, logs and quit actions. Settings
support showing the window and entering fullscreen when mirroring starts,
keeping playback above other windows and retaining the receiver in the tray.

Closing to the tray disconnects the current session and leaves reception
available. A window automatically opened for a session hides three seconds
after playback ends; manually opening it cancels that behavior. If no tray host
is connected, close exits normally. If the tray host disappears while the
window is hidden, the application shows the window again.

## Media support

- H.264 Annex B software decoding to RGBA, including SPS/PPS updates, portrait
  changes and reordered frames. Shared deadlines and generations accompany each
  decoded frame
- ALAC uses the existing Apple decoder; AAC-LC and AAC-ELD use FFmpeg's native
  floating-point AAC decoder
- Audio is 44.1 kHz stereo S16. AAC-LC configuration supports 960/1024 samples;
  AAC-ELD supports the common AirPlay 480/512-sample configurations without
  low-delay SBR. Unsupported output formats and corrupt packets fail explicitly
- FLUSH invalidates queued PCM and decoded video. PulseAudio's queued old PCM is
  flushed on the next device pull; already delivered hardware samples cannot be
  recalled
- HEVC is not advertised by the shared receive core

## Regressions

```sh
flutter analyze
flutter test
./linux/test_native.sh
```

The native suite needs `ffmpeg`, `ffprobe` and Python 3 to generate synthetic
B-frame fixtures. It covers receive-core loopback RTSP/TXT, repeated lifecycle,
video pixels/rotation/reordering/keyframe recovery, ALAC/AAC/ELD decoding,
malformed-input recovery, bounded queues, timeline/FLUSH and pause/resume within
a GOP. It does not establish real iPhone discovery, real sender playback,
speaker output, or hardware A/V synchronization.

Install `xvfb` and `dbus-x11` to enable the GTK window/tray runtime regression.
It runs on an isolated display and session bus with a synthetic tray watcher,
and verifies sizing, rotation, fullscreen restoration, tray menus, close/show
and recovery after the watcher disappears. It does not establish compatibility
with every real desktop environment.

For actual caption dragging, install `xvfb`, `dbus-x11`, `openbox` and `xdotool`,
build the Debug app, then run `./linux/test_window.sh`. It starts the real root
Flutter UI on an isolated X11 desktop with reception disabled, moves the caption
using mouse input, verifies the resulting window coordinates and size, and then
clicks close to check that mouse input still works after dragging. Pass a bundle
directory to test another build, for example:

```sh
./linux/test_window.sh "$PWD/build/linux/x64/release/bundle"
```

After a Flutter Linux build, the native suite also runs the real Flutter
channel/texture host tests without a display. A developer-only visual fixture
can load the same root UI and decode a synthetic H.264 image into its texture:

```sh
LD_LIBRARY_PATH="$PWD/build/linux/x64/release/bundle/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  ./build/linux-native/linux_synthetic_demo "$PWD/build/linux/x64/release/bundle"
# Add `portrait` for the portrait fixture.
```

This fixture is not installed or enabled in the product. Its title and logs mark
it as synthetic; it never starts the receive core, discovery or audio output.
