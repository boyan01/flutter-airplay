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

The UI redesign adds a bounded `AIRPLAY_RECEIVER_EVENT client <name>` event
for admitted senders. Control bytes are removed so names cannot inject event
lines. Android receives the same client-request callback through its JNI host;
client identity never establishes decoded video readiness.

Audio no-data packets retain their sequence slots in the shared RTP reorder
buffer. Dequeue skips their empty payloads while preserving retransmission for
actual packet loss. FLUSH clears this buffer and applies the sender's next
sequence before flushing platform playback.

Control request and response summaries are logged at INFO level to diagnose
handshake progress without enabling headers, key material or payload dumps.

The macOS executable enables legacy pairing by default, matching the Android
host's advertised capability when an iPhone switches between receivers.

For an upstream update, compare or merge from the base commit, update this
record, and run the platform builds and native regressions. Keep upstream
updates separate from feature changes.
