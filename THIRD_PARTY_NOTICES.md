# Third-party notices

Flutter AirPlay is offered under GPL-3.0-or-later; see LICENSE.

## UxPlay

Source: https://github.com/FDH2/UxPlay
Version: v1.73.7, upstream commit df67c212a433cf6dda3676dd40c097900d24e645.
Copyright and upstream license notices are retained in vendor/UxPlay.
UxPlay's top-level license is GPLv3. Included lib/llhttp code has its own MIT
license. Retain all source-level notices and licenses when redistributing.

Local modifications: uxplay.cpp emits ready / streaming / waiting process events
and flushes stdout by line when launched with pipes.
Audio/video renderer and RTP changes add low-rate packet/decode/volume/signal
and clock/PTS/queue diagnostics,
fix clock reference ownership and safely discard empty/invalid buffers.
RTP restarts clear old timing anchors; mirror timestamp outliers are rejected;
same-codec SETUP and FLUSH reset the native audio pipeline without changing gain.
Embedded Flutter frame transport and partial-initialization/DNS lifetime fixes
are also maintained directly in vendor/UxPlay. Upstream provenance is recorded
in vendor/UxPlay/UPSTREAM.md; Git tracks the local modifications. The receive
core is shared by macOS and Android. macOS decode/playback remains in UxPlay
and GStreamer. No Go code is used.

## Flutter and GStreamer

Flutter: https://github.com/flutter/flutter (BSD-3-Clause); the installed SDK and
its notices remain external. The generated application includes Flutter's native
framework and its license metadata. Flutter dependencies are locked in pubspec.lock.

GStreamer: https://gstreamer.freedesktop.org (principally LGPL, with individual
plugin/dependency licenses). This prototype dynamically uses the user's installed
Homebrew GStreamer. A future standalone package must audit and retain the actual
GStreamer, FFmpeg, OpenSSL, libplist and transitive dependency notices and provide
corresponding source/other required materials as appropriate. This local prototype
is not a ready-to-distribute universal bundle.

## Android reference

The Android player includes source derived from
https://github.com/jqssun/android-airplay-server. Copied paths and the upstream
commit are recorded in android/dependencies.lock.json. See android/NOTICE,
android/CORE_NOTICE.md and the bundled APK license assets.
