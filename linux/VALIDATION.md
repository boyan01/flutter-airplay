# Linux implementation validation — 2026-10-03

Baseline: private project commit `4790029714feffd28092216ec25ce7a7bf6813f6`.
Linux-only changes and the shared CMake/analyzer integration patch are separate
handoff artifacts. Shared Windows/iPad integration must be retested after merge.

## Environment

- Debian 13 x86_64 cloud computer, Xorg desktop
- Flutter 3.47.2 / Dart 3.13.2, matching `.fvmrc`
- Clang 19.1.7, CMake 3.31.6, GTK 3.24.49
- FFmpeg 7.1.5, PulseAudio client 17, Avahi client 0.8, libplist 2.6
- Official development packages extracted into a workspace-only sysroot
- Flutter's official BOT/CI switches disable automatic cloud-instance probing;
  analytics is suppressed. No metadata endpoint access was authorized

## Completed

- `flutter analyze`: no issues
- `flutter test`: all 32 existing root tests pass on Linux, including native
  dependency compilation
- `flutter build linux --debug` and `flutter build linux --release`: pass;
  Release bundle is approximately 27 MiB before distribution dependencies
- Seven CTest tests pass. These include three GTK host subtests:
  - Shared clock, bounded PCM, gain, deadlines, FLUSH, concurrent ring wraparound
  - ALAC 352/4096, AAC-LC 1024 and AAC-ELD 480/512 actual decoded non-silent PCM;
    malformed/truncated input, unsupported formats, queue saturation and recovery
  - H.264 RGBA pixels, independent parameter sets, portrait changes, reset,
    malformed input, maximum dimensions, real B-frame deadline/generation reorder
  - Shared receive callbacks: pause/resume in the same GOP changes pixels without
    resetting continuing audio or the media clock
  - Three receive-core start/stop cycles, TXT codec declarations and actual
    loopback RTSP OPTIONS responses
  - Missing Pulse server returns failure and repeated stop/destruction is safe
  - Real Flutter message codecs, channels, RGBA copy_pixels lifetime/stride/
    concurrent updates, settings persistence, pending-call cancellation and
    complete handler removal
  - Unavailable Avahi reports an error, pid=0 and never emits waiting
- Audio decoder, video adapter and GTK host targeted ASan/UBSan tests pass with
  `detect_leaks=0`. System media libraries were not instrumented; LeakSanitizer
  could not run under the container's ptrace restriction
- Actual desktop application started through the cloud desktop terminal. The
  root Flutter UI displayed the Avahi-daemon error; Retry, log viewer, Back and
  window-manager close were exercised
- Actual synthetic desktop texture path: existing H.264 fixture → Linux software
  decoder → owned RGBA → Flutter texture → unchanged root UI. Landscape
  640×360 and Release portrait 360×640 rendered red with correct letterboxing.
  The independent developer fixture was explicitly labelled synthetic and did
  not start a receiver or discovery service

## Remaining verification limits

- The cloud desktop has no running Avahi/system-bus service and no physical
  PulseAudio/PipeWire output. Real service publication, device playback and
  speaker sound were not verified
- A temporary null-sink attempt was stopped after the shell sandbox denied Unix
  sockets. No TCP fallback, public port, firewall change, VPN or access workaround
  was used
- The cloud computer and the user's iPhone are not on the same LAN. No claim is
  made about real iPhone discovery, playback, hardware A/V sync, sustained 60 FPS
  or production distribution readiness
- AAC-ELD low-delay SBR and nonstandard output formats are unsupported. AAC-LC
  960 configuration is accepted but the existing positive fixtures cover 1024
- The shared 4790029 UI still has Mac-specific footer/control labels on Linux;
  the shared UI owner must integrate the platform changes. Linux provides its
  GTK fullscreen/close/minimize channel, but does not implement always-on-top,
  menu-bar residence or launch-at-login settings
