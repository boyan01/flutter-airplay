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

The Windows `snprintf` fallback applies only to pre-Visual Studio 2015 MSVC.
Modern MSVC and ClangCL use the CRT's standard declaration without macro aliases.

The embedded HTTP listener explicitly creates and destroys its lifecycle mutex.
Zero-filled storage is not a valid initialized Windows critical section.

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

The shared C++ host enables legacy pairing on both platforms. Its build
overrides `RAOP_CN` to advertise only ALAC, AAC and AAC-ELD, which its bundled
FFmpeg decoder supports. The upstream default remains available to other hosts.
The current Flutter application uses the C++ library rather than the vendored
GStreamer executable and its frame socket.

The HEVC mirror configuration validates the complete VPS/SPS/PPS arrays and
their lengths before reading or copying them. Encrypted video NAL parsing
also rejects truncated length prefixes and empty or undersized NAL units.
Platform playback capabilities control ScreenMultiCodec advertisement.

For an upstream update, compare or merge from the base commit, update this
record, and run the platform builds and native regressions. Keep upstream
updates separate from feature changes.
