# Android receiver foundation notices

New bridge, TXT storage adapter, Java NSD adapter and tests are GPL-3.0-or-later.
`COPYING` contains GPL version 3. This module preserves the receive/playback
boundary; it has no Go component and does not include a GStreamer renderer.

The receive implementation is generated from the project's locked
[UxPlay v1.73.7](https://github.com/FDH2/UxPlay/tree/df67c212a433cf6dda3676dd40c097900d24e645),
including its original per-file copyright and LGPL/GPL notices. Its bundled
PlayFair and llhttp licenses remain in the vendored source tree. Builds apply
only the existing receiver patch's core changes, plus the Android-only lifetime
patch, to a disposable source copy. Never modify `vendor/UxPlay`.

Android architecture and the libplist source-build approach were studied from
[jqssun/android-airplay-server](https://github.com/jqssun/android-airplay-server/tree/c8defdd70d7e6a04f4f1b71d353653682d594106)
(GPL-3.0). No reference application UI, JNI implementation, renderer or DNS shim
source was copied. The adapter here preserves the locked core's original TXT
generation rather than using the reference project's newer UxPlay structures.

Native dependencies are pinned in `dependencies.lock.json`: libplist 2.6.0
(LGPL-2.1-or-later), OpenSSL 3.6.4 (Apache-2.0). Their corresponding source can
be fetched with `scripts/fetch_deps.py`. License texts are also packaged in AAR
assets. Redistributing the library requires the corresponding source and
applicable license obligations; the AAR alone is not a source distribution.
