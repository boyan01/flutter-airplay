# Third-party source provenance

This file records third-party source maintained directly in this repository.
Flutter package license notices are collected by Flutter and are not duplicated here.

## UxPlay

Source: https://github.com/FDH2/UxPlay
Base version: v1.73.7
Base commit: df67c212a433cf6dda3676dd40c097900d24e645

The shared receive core is maintained in `vendor/UxPlay/`. Upstream provenance
and local modifications are recorded in [UPSTREAM.md](vendor/UxPlay/UPSTREAM.md).
Original copyright and license notices remain with the source.

## Shared C++ player and Android reference

The shared player retains derived AirPlay audio configuration and device-loss
handling. The Android decoder selector also derives from
https://github.com/jqssun/android-airplay-server.
Copied paths and the upstream commit are recorded in
[dependencies.lock.json](native/dependencies.lock.json).
Source notices are retained in [NOTICE](android/NOTICE),
[CORE_NOTICE.md](android/CORE_NOTICE.md) and the bundled
[license assets](assets/licenses/).

## Apple ALAC decoder

Source: https://github.com/macosforge/alac
Base commit: c38887c5c5e64a4b31108733bd79ca9b2496d987
License: Apache-2.0

Decoder sources are maintained in `vendor/alac/` and linked on Android, Windows
and Linux.
The encoder and conversion utility are excluded. Original copyright and license
notices remain with the source. Local input-bound checks are recorded in
[UPSTREAM.md](vendor/alac/UPSTREAM.md). The license is bundled in
[ALAC-Apache-2.0.txt](assets/licenses/ALAC-Apache-2.0.txt).

## FFmpeg media decoding

Windows and Linux share `native/backends/ffmpeg/ffmpeg_audio_decoder.cpp` and
`native/backends/ffmpeg/ffmpeg_video.cpp`. Windows builds
FFmpeg n7.1.5 from source commit `3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587`,
pinned in [dependencies.lock.json](native/dependencies.lock.json).
Source: https://github.com/FFmpeg/FFmpeg.
The Windows configuration enables the native float AAC and HEVC decoders in shared
libavcodec, libavutil, libswresample and libswscale, without GPL/nonfree components
or external codecs. HEVC software decoding backs up the system Media Foundation
decoder. The upstream source is unmodified. Build options are recorded in
[build_ffmpeg.sh](windows/scripts/build_ffmpeg.sh) and included in Windows packages.
The LGPL-2.1-or-later license and source/build notices are bundled in the existing
[license assets](assets/licenses/).
Redistributions must retain the corresponding source and exact build configuration.

## Linux system dependencies

The Linux host links distribution-provided FFmpeg, GTK/GLib, PulseAudio, Avahi,
OpenSSL and libplist libraries. It does not vendor those sources or use FDK-AAC.
Dependency licensing and distribution requirements are recorded in
[NOTICE](linux/NOTICE). Preserve the exact notices and licenses of any packages
included in a distribution; installed system libraries remain runtime dependencies.
