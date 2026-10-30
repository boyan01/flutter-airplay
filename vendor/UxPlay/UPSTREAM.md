# UxPlay source maintained by Flutter AirPlay

Upstream: https://github.com/FDH2/UxPlay
Base version: post-v1.73.7 main (unreleased, 2026-10-28)
Base commit: 534e2cc0e558d6c94bcc66964f8fc13ad73a6cdc

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

An optional `audio_stop` callback fires when the audio receive thread exits,
after its final packet callback. Embedded hosts use it to close audio output
when the transport ends, while ordinary FLUSH keeps the output available.

Control request and response summaries are logged at INFO level to diagnose
handshake progress without enabling headers, key material or payload dumps.

The shared C++ host enables legacy pairing by default on every platform.
The optional Fast pairing setting disables feature bit 27 in both discovery TXT
records and RTSP info, avoiding the legacy pairing advertisement. Its build
overrides `RAOP_CN` to advertise only ALAC, AAC and AAC-ELD, which its bundled
FFmpeg decoder supports. The upstream default remains available to other hosts.
The current Flutter application uses the C++ library rather than the vendored
GStreamer executable and its frame socket.

The HEVC mirror configuration validates the complete VPS/SPS/PPS arrays and
their lengths before reading or copying them. Encrypted video NAL parsing
also rejects truncated length prefixes and empty or undersized NAL units.
Platform playback capabilities control ScreenMultiCodec advertisement.

The receive core includes upstream changes through the commit above, including
llhttp 9.4.2, pairing fixes and revised NTP synchronization. The embedded build
uses the external DNS-SD backend for Apple discovery and TXT storage; Android
retains NsdManager, Linux retains its Avahi host, and Windows retains its system
DNS-SD adapter. The experimental upstream mdnsd backend is not enabled.
Windows keeps DNS metadata opaque and uses recvfrom rather than kernel timestamp
I/O because the host maps integer descriptors to Windows SOCKET handles.
The host initializes NTP globals once before starting a receiver. Apple Bonjour
registration replies are serviced by an owned thread, joined before DNS cleanup;
processing failures are reported through receiver error events. Android, Linux and Windows
continue to let their platform discovery APIs own network events.

The combined codec/geometry callback fires for every mirror configuration,
including same-codec size changes, so sender rotation still updates host state.
HEVC parameter arrays retain bounds checks when copied into the upstream fixed
configuration buffer.

Valid NTP samples publish the client-time flag with the synchronized clock offset;
clock conversions read both under the same lock. Audio stop clears its timestamp
session so a failed restart cannot free it again. Oversized H.264/HEVC mirror
configurations end the connection before another frame can use their lengths.
The host joins mirror threads even after a protocol error has already ended them.
H.264 mirror configurations validate the SPS and PPS lengths against the payload
before reading them, and end the connection when either is empty or truncated.
Cached SPS/PPS is prepended only when present and the frame timestamp differs.

Fixes submitted upstream, to drop here once merged: FDH2/UxPlay#630 (NTP client
time flag), #631 (httpd mutex, audio timestamp session, mirror thread join and
payload leak, SPS/PPS prepend condition) and #632 (MinGW `snprintf`). The H.264
configuration bounds checks were reported privately to the maintainer.
Upstream fixed audio no-data packets differently (ec20312); this tree keeps its
own reorder-buffer handling described above.

For an upstream update, compare or merge from the base commit, update this
record, and run the platform builds and native regressions. Keep upstream
updates separate from feature changes.
