# UxPlay source maintained by Flutter AirPlay

Upstream: https://github.com/FDH2/UxPlay
Base version: v1.73.7
Base commit: df67c212a433cf6dda3676dd40c097900d24e645

This directory contains the project's maintained UxPlay sources. Edit them
here; macOS and Android compile the same receive core directly. Build outputs
belong in ignored build directories. Git records the exact project version.

Local changes include receiver state events, audio/video diagnostics, clock
ownership and RTP recovery, embedded Flutter frame transport, and safe cleanup
of partially initialized receivers and DNS objects. Original source-level
copyright and license notices are retained.

For an upstream update, compare or merge from the base commit, update this
record, and run the platform builds and native regressions. Keep upstream
updates separate from feature changes.
