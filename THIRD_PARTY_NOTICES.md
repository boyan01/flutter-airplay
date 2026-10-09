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

## Sparkle macOS updates

Source: https://github.com/sparkle-project/Sparkle
Version: 2.10.0, pinned exactly by the macOS Swift Package Manager dependency.

The macOS host embeds the unmodified Sparkle framework and its update helpers.
Sparkle's MIT license and bundled components' BSD, MIT and zlib notices are
retained in [sparkle.txt](assets/licenses/sparkle.txt). Its upstream binary
package checksum is verified by Swift Package Manager.

## Linux system dependencies

The Linux host links distribution-provided FFmpeg, GTK/GLib, PulseAudio, Avahi,
OpenSSL and libplist libraries. It does not vendor those sources or use FDK-AAC.
Dependency licensing and distribution requirements are recorded in
[NOTICE](linux/NOTICE). Preserve the exact notices and licenses of any packages
included in a distribution; installed system libraries remain runtime dependencies.

## Windows installer and runtime

The Windows installer is built with Inno Setup 6.6 or newer. CI pins version 6.7.3.
Source: https://github.com/jrsoftware/issrc. The upstream Inno Setup license is
retained in [Inno-LICENSE.txt](windows/installer/Inno-LICENSE.txt).
The unmodified Simplified Chinese translation in
[ChineseSimplified.isl](windows/installer/ChineseSimplified.isl) comes from upstream
commit `16839f1de8cc6e770246260e50557d141f5fa961`, file
`Files/Languages/ChineseSimplified.isl`; its maintainer notices are preserved.

The installer includes app-local x64 Microsoft Visual C++ CRT DLLs copied from
Visual Studio 2022's `VC/Redist/MSVC/<version>/x64/Microsoft.VC143.CRT` directory.
These binaries remain subject to Microsoft's Visual Studio redistribution terms:
https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution.
The package does not replace system runtime libraries.
