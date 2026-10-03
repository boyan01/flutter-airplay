# Android receiver foundation notices

The retained TXT storage adapter and synthetic receiver tests are GPL-3.0-or-later.
`COPYING` contains GPL version 3. The Android host preserves the receive/playback
boundary; it has no Go component and does not include a GStreamer renderer.

The receive implementation is maintained in `vendor/UxPlay`, based on
[UxPlay v1.73.7](https://github.com/FDH2/UxPlay/tree/df67c212a433cf6dda3676dd40c097900d24e645),
including its original per-file copyright and LGPL/GPL notices. Its bundled
PlayFair and llhttp licenses remain in the vendored source tree. Receiver integration and lifetime fixes are part of the maintained source,
shared with macOS. Upstream provenance is in `vendor/UxPlay/UPSTREAM.md`.

Android architecture and the libplist source-build approach were studied from
[jqssun/android-airplay-server](https://github.com/jqssun/android-airplay-server/tree/c8defdd70d7e6a04f4f1b71d353653682d594106)
(GPL-3.0). No reference DNS shim source was copied into this core adapter. The player
and renderer provenance is recorded separately in `NOTICE`. The adapter preserves the upstream base's TXT
generation rather than using the reference project's newer UxPlay structures.

Native dependencies are pinned in `dependencies.lock.json`: libplist 2.6.0
(LGPL-2.1-or-later), OpenSSL 3.6.4 (Apache-2.0). Their corresponding source can
be fetched with `scripts/fetch_deps.py`. License texts are packaged in APK assets. Redistributing the application
requires the corresponding source and applicable license obligations; the APK
alone is not a source distribution.
