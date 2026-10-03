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
The complete modifications are in native/patches/0001-receiver-integration.patch. Receive/decode/playback
remain in UxPlay and GStreamer. No Go code is used.

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

https://github.com/jqssun/android-airplay-server was reviewed as context for future
Android work. No Android implementation or source was copied into this phase.
