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
[dependencies.lock.json](android/dependencies.lock.json).
Source notices are retained in [NOTICE](android/NOTICE),
[CORE_NOTICE.md](android/CORE_NOTICE.md) and the bundled
[license assets](android/app/src/main/assets/licenses/).

## Apple ALAC decoder

Source: https://github.com/macosforge/alac
Base commit: c38887c5c5e64a4b31108733bd79ca9b2496d987
License: Apache-2.0

Decoder sources are maintained in `vendor/alac/` and linked on Android, Windows
and Linux.
The encoder and conversion utility are excluded. Original copyright and license
notices remain with the source. Local input-bound checks are recorded in
[UPSTREAM.md](vendor/alac/UPSTREAM.md). The license is bundled in
[ALAC-Apache-2.0.txt](android/app/src/main/assets/licenses/ALAC-Apache-2.0.txt).

## Linux system dependencies

The Linux host links distribution-provided FFmpeg, GTK/GLib, PulseAudio, Avahi,
OpenSSL and libplist libraries. It does not vendor those sources or use FDK-AAC.
Dependency licensing and distribution requirements are recorded in
[NOTICE](linux/NOTICE). Preserve the exact notices and licenses of any packages
included in a distribution; installed system libraries remain runtime dependencies.
