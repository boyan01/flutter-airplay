# Playback fixtures

`main.cpp` exercises the production C++ timeline, bounded PCM buffer, audio
configuration and VideoToolbox adapter. It also starts the production receive
core, sends loopback RTSP requests and destroys/recreates the player.

`audio_clock_tests.h` checks uninterrupted 440 Hz PCM while replaying device
presentation-time jitter, then checks output-clock reset and reanchoring after
a long interruption. Both the host regression and the Android fixture run it.

Audio fixtures contain only a synthetic 880 Hz stereo tone. `audio_fixtures.h`
was generated from FFmpeg AAC/ALAC and macOS AudioToolbox AAC-ELD packets. ALAC
uses a 4096-sample frame; AAC uses 1024; AAC-ELD uses 512. These do not cover every
sender configuration (in particular, AirPlay's 352/480-sample variants).

Video fixtures contain one synthetic red frame in landscape and portrait,
encoded with FFmpeg/libx264. The test checks decoded BGRA pixels, actual
H.264 dimensions, SPS changes and reset/keyframe recovery.

`session_test.cpp` exercises the production receive callback bindings with a
continuous red-to-blue H.264 GOP. It pauses video presentation, feeds a queued
inter frame, then resumes without a new IDR. The test requires fresh blue
output and preservation of queued audio and the shared timeline.
It also checks distinct sender-pause and decoded-audio events, including the
audio-flush event that clears the UI's audio state. It compiles
the receive callback translation unit into the fixture to avoid a test-only
public player API. The Android fixture also verifies the resumed GPU pixels
with the hardware and software decoder.

`android/` uses the same fixtures and packaged library in a separate test app.
It feeds four frames per session because the system software decoder can buffer
initial frames. It checks both the default and an available hardware decoder.
Its GLES SurfaceTexture consumer checks actual GPU pixels (some hardware
drivers do not support CPU-readable ImageReader planes); Oboe is opened with an empty
buffer so the test does not emit a tone. This exercises platform playback,
not Flutter's application host, discovery or a real AirPlay sender.

Run the current scripts documented in the root AGENTS.md. Synthetic results
cannot establish iPhone interoperability, audible output or A/V synchronization.
