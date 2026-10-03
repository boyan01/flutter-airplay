# Linux host

Linux uses the root Flutter application (`lib/main.dart`) and the same C++
receiver, clock, bounded PCM queue and session lifecycle as the other platforms.
The GTK host embeds decoded video in a Flutter texture; it does not launch an
external player or subprocess.

## Dependencies and build

Use the Flutter version pinned in `.fvmrc`. The software baseline requires
FFmpeg 6 or newer (`libavcodec >= 60`), GTK 3, PulseAudio or PipeWire's PulseAudio
compatibility server, Avahi, OpenSSL and libplist 2.3 or newer. Debian 13 is the
validated build environment; older distributions may need newer development
packages.

On Debian 13:

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
  libavcodec-dev libavutil-dev libswscale-dev libswresample-dev \
  libpulse-dev libavahi-client-dev libssl-dev libplist-dev libx11-dev libxi-dev
flutter pub get
flutter build linux --release
./build/linux/x64/release/bundle/flutter_airplay
```

The bundle includes the shared player library. GTK, FFmpeg, PulseAudio, Avahi,
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
unregistering the texture. Linux does not offer launch-at-login integration or
an external executable path.

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
