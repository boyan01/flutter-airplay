# Third-party source provenance

This file records third-party source maintained directly in this repository.
Flutter package license notices are collected by Flutter and are not duplicated here.

## UxPlay

Source: https://github.com/FDH2/UxPlay
Base version: post-v1.73.7 main (unreleased, 2026-10-28)
Base commit: 534e2cc0e558d6c94bcc66964f8fc13ad73a6cdc

The shared receive core is maintained in `vendor/UxPlay/`. Upstream provenance
and local modifications are recorded in [UPSTREAM.md](vendor/UxPlay/UPSTREAM.md).
Original copyright and license notices remain with the source.

## Android decoder selector

The Android decoder selector derives from
https://github.com/jqssun/android-airplay-server.
Copied paths and the upstream commit are recorded in
[dependencies.lock.json](native/dependencies.lock.json).
Source notices are retained in [NOTICE](android/NOTICE),
[CORE_NOTICE.md](android/CORE_NOTICE.md) and the bundled
[license assets](assets/licenses/).

## lychee_player

Source: https://github.com/boyan01/lychee_player
License: MIT

Every platform decodes, outputs audio and times frames through the lychee_player
C ABI, taken from its Flutter plugin (DEVELOPMENT.md). Apple platforms and
Android link its FFmpeg-free core. Windows and Linux ship the LGPL-2.1-or-later
FFmpeg its release pins, built without GPL or nonfree components and linked
dynamically. lychee_player's own notices, including FFmpeg's, are bundled in
[lychee_player-NOTICES.txt](assets/licenses/lychee_player-NOTICES.txt).

## Sparkle macOS updates

Source: https://github.com/sparkle-project/Sparkle
Version: 2.10.0, pinned exactly by the macOS Swift Package Manager dependency.

The macOS host embeds the unmodified Sparkle framework and its update helpers.
Sparkle's MIT license and bundled components' BSD, MIT and zlib notices are
retained in [sparkle.txt](assets/licenses/sparkle.txt). Its upstream binary
package checksum is verified by Swift Package Manager.

## libplist and BoringSSL

Sources: https://github.com/libimobiledevice/libplist and
https://boringssl.googlesource.com/boringssl (GitHub mirror google/boringssl).
Versions, archives and SHA-256 are pinned in
[dependencies.lock.json](native/dependencies.lock.json); builds download and
compile the unmodified release sources. Every host compiles in libplist
(LGPL-2.1-or-later). Android, Windows, macOS and iPad compile in BoringSSL's
libcrypto (Apache-2.0); Linux uses the distribution's OpenSSL 3. Their licenses
are retained in [libplist-LGPL-2.1.txt](assets/licenses/libplist-LGPL-2.1.txt)
and [BoringSSL-LICENSE.txt](assets/licenses/BoringSSL-LICENSE.txt).

## Linux system dependencies

The Linux host links distribution-provided GTK/GLib, PulseAudio, Avahi and
OpenSSL libraries. It does not vendor those sources or use FDK-AAC.
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
