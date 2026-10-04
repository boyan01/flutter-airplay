# Playback fixtures

`main.cpp` exercises the production C++ timeline, bounded PCM buffer, audio
platform audio decoder and VideoToolbox adapter. It also starts the production receive
core, sends loopback RTSP requests and destroys/recreates the player.

`audio_clock_tests.h` checks uninterrupted 440 Hz PCM while replaying device
presentation-time jitter, then checks output-clock reset and reanchoring after
a long interruption. Both the host regression and the Android fixture run it.

Audio fixtures contain only a synthetic 880 Hz stereo tone. `audio_fixtures.h`
was generated from FFmpeg AAC/ALAC and macOS AudioToolbox AAC-ELD packets. ALAC
uses a 4096-sample frame; AAC uses 1024; AAC-ELD uses 512 and 480.
`audio_decoder_tests.h` also constructs a synthetic 352-sample uncompressed
ALAC stereo packet. Both platform fixtures check queued PCM deadlines, format
changes and FLUSH/restart. Android's system AAC decoder can buffer initial
packets, so the fixtures feed a continuing stream before checking PCM.

`alac_test.cpp` exercises the same standalone decoder used on Android. It checks
bit-exact 352-sample PCM, compressed 4096-sample ALAC, oversized and truncated
frames, 10000 deterministic malformed packets, and recovery after invalid input.
Run `ALAC_SANITIZE=ON ./scripts/test_alac.sh` for the AddressSanitizer host build.

Video fixtures contain one synthetic red frame in landscape and portrait,
encoded with FFmpeg/libx264. The test checks decoded BGRA pixels, actual
H.264 dimensions, SPS changes and reset/keyframe recovery. macOS also runs
60 FPS B-frame input and checks that output follows presentation timestamps
without early or backwards submission. A production-worker fixture sends nine
frames in a burst, requires decoding to finish before presentation starts, and
checks scheduled output and cancellation of retained pixel buffers on reset.
An arrival-jitter case delays one TCP frame by 100 ms, releases the following
frames as a burst, and checks that the shared macOS audio/video buffer absorbs
that stall without losing frames or adding a submission gap over 30 ms.
These callbacks measure submission to the texture adapter, not Flutter raster
consumption or physical display scanout.

`session_test.cpp` exercises the production receive callback bindings with a
continuous red-to-blue H.264 GOP. It pauses video presentation, feeds a queued
inter frame, then resumes without a new IDR. The test requires fresh blue
output and preservation of queued audio and the shared timeline.
It also checks distinct sender-pause and decoded-audio events, including the
audio-flush event that clears the UI's audio state. It compiles
the receive callback translation unit into the fixture to avoid a test-only
public player API. The Android fixture also verifies the resumed GPU pixels
with the hardware and software decoder. It also switches between two output
surfaces and returns to the first without a new IDR, requiring blue pixels and
an unchanged media clock after each switch.
The macOS host also sends a burst of synthetic ALAC packets without synchronized
NTP timestamps. It requires continuous PCM scheduled from the RTP sample clock,
including 32-bit RTP wraparound, a new RTP anchor after FLUSH, and authoritative
NTP timestamps when available. Packet arrival times must not collapse a burst's
PCM deadlines and discard most of its sound.

The macOS receive-callback fixture also negotiates HEVC, checks decoded BGRA
colors and dimensions for landscape, portrait, 4K and Main10 input, then resets
and reconnects with H.264. `hevc_fixtures.h` contains synthetic FFmpeg/libx265
color frames only, with encoder information SEI disabled. The `/info` fixture
checks that ScreenMultiCodec advertisement matches platform decoding support.
The shared RTP fixture checks HEVC parameter arrays at every truncation length,
with empty and oversized parameter lengths, before any parameter is copied.

Android's separate fixture also decodes the HEVC landscape, portrait, 4K and
Main10 color frames into its GPU SurfaceTexture and checks reset/restart.
iPad uses the same fixtures through VideoToolbox; its HEVC test skips explicitly
when the simulator has no hardware HEVC decoder.
Linux and the Windows software fallback share the FFmpeg adapter. Run
`./scripts/test_ffmpeg_video.sh` (or `FFMPEG_SANITIZE=ON` for ASan/UBSan) on a
host with FFmpeg 6+ development libraries, FFmpeg/ffprobe and Python 3. It checks
HEVC pixels, split VPS/SPS/PPS, rotation, Main10, 4K, malformed recovery and
codec switches alongside the H.264 B-frame timing regression. Windows also has
`windows_video` and `windows_hevc_software` CTest fixtures for its platform path
and packaged decoder. A host FFmpeg test does not establish Windows MFT support,
Linux GTK playback, Android TV behavior or real iPad sender interoperability.

`android/` uses the same fixtures and packaged library in a separate test app.
It feeds four frames per session because the system software decoder can buffer
initial frames. It checks both the default and an available hardware decoder.
Its GLES SurfaceTexture consumer checks actual GPU pixels (some hardware
drivers do not support CPU-readable ImageReader planes); Oboe is opened with an empty
buffer so the test does not emit a tone. This exercises platform playback,
not Flutter's application host, discovery or a real AirPlay sender.

The Android pacing fixture feeds 60 FPS timestamps through the production
receiver worker, with one, three or nine compressed frames arriving per batch.
It samples the GPU SurfaceTexture at approximately 120 Hz and checks for early
presentation, skipped frame timestamps and long presentation gaps. It also
resets the receiver while a decoded frame is waiting for its deadline and
requires fresh output without the cancelled frame. The fixture runs against
the available default, hardware, low-latency and software AVC decoders.
On Qualcomm AVC decoders, `ReorderTest` also exercises 1440p30 with POC type 0
and no SPS bitstream restriction, then a stream with real B-frames. It requires
60 measured images without early or backwards presentation. The first case
catches decoder buffering that can make every output miss its deadline; the
second catches a future reference frame blocking earlier presentation timestamps.
`reorder_fixtures.h` contains only synthetic red video. Regenerate it with
`python3 native/player-tests/generate_reorder_fixtures.py` (FFmpeg and x264 CLI).
Texture consumption times do not measure physical display scanout.

For additional pacing diagnostics, `PacingTest` accepts `--phase-sweep` after
its decoder argument when launched with `app_process`. This samples at 120 and
60 Hz with 0, 3, 7, 11 and 15 ms offsets, retaining the same loss/gap assertions.
The 60 Hz sweep is a stress diagnostic, not part of the default regression:
a timer-driven consumer can race asynchronous SurfaceTexture delivery at the
same frame rate. Failures must be reported; this test does not simulate Android
Choreographer or Flutter raster scheduling. Copy `classes.dex`,
`libairplay_player.so` and `libplayer_regression.so` from the fixture build to a
local device directory, set `CLASSPATH` to that dex file, and pass the directory
and decoder name to `tech.soit.flutterairplay.player_regression.PacingTest`.

Run the current scripts documented in the root AGENTS.md. Synthetic results
cannot establish iPhone interoperability, audible output or A/V synchronization.
