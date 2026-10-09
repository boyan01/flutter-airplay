// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AirplayPlayer AirplayPlayer;
// Callbacks may run on native workers. Their context must outlive player_destroy.
// frame is a borrowed CVPixelBuffer on Apple platforms; Android renders to Surface.
// Windows uses a borrowed WindowsVideoFrame (windows_video.h). Linux defines its
// own borrowed frame descriptor. Hosts must copy or retain before returning.
// deadline_ns is the presentation deadline on the platform monotonic clock,
// shared with audio (CLOCK_MONOTONIC on Apple/POSIX).
// Media events: playing carries decoded video dimensions; paused hides video
// until a fresh playing event; audio marks queued PCM; audio_stopped clears it.
// reset clears both media states; waiting ends the sender session.
typedef struct {
    void *context;
    void (*event)(void *, const char *type, const char *detail, int width, int height);
    void (*frame)(void *, void *frame, int64_t deadline_ns);
    void (*log)(void *, int level, const char *message);
} AirplayCallbacks;

// surface is a borrowed ANativeWindow on Android; create retains its own reference.
// It is unused on macOS. Linux accepts optional AirplayLinuxVideoOptions
// (linux_video.h), copied at create.
// Windows accepts optional WindowsVideoOptions (windows_video.h), copied at create.
AirplayPlayer *airplay_player_create(AirplayCallbacks callbacks, void *surface,
                                    const char *decoder, const char *fallback);
#ifdef __ANDROID__
// Synchronously moves Android video output without resetting codec references.
// surface is borrowed; call on the same lifecycle thread as start/destroy.
bool airplay_player_set_surface(AirplayPlayer *, void *surface);
// Android output selection: 0=auto, 1=AAudio, 2=AudioTrack. Before receiver start.
bool airplay_player_set_audio_output(AirplayPlayer *, int mode);
// Enables Android HEVC with a capability-checked decoder name before start.
bool airplay_player_set_hevc_decoder(AirplayPlayer *, const char *decoder);
#endif
// Sets the advertised size before start; the sender chooses actual frame dimensions.
// Defaults to 1920x1080. Call on the same lifecycle thread as start/destroy.
bool airplay_player_set_video_size(AirplayPlayer *, int width, int height);
// Sets the shared audio/video buffer: 0=platform default, or 40, 60, 80, 100, 120, 150, 200, 300 ms.
// Call on the lifecycle thread before start; a running timeline cannot be changed.
bool airplay_player_set_playback_buffer(AirplayPlayer *, int milliseconds);
// Skips legacy pairing when enabled. Defaults to true; set before receiver start.
bool airplay_player_set_fast_pairing(AirplayPlayer *, bool enabled);
bool airplay_player_start(AirplayPlayer *, const char *name, const uint8_t identity[6],
                          const char *key_path, char *error, size_t error_size);
uint16_t airplay_player_port(AirplayPlayer *);
size_t airplay_player_txt(AirplayPlayer *, bool audio, uint8_t *output, size_t capacity);
// Reserves an idle receiver for replacement. False preserves any connection,
// including one whose host/UI event has not arrived yet. On true, destroy the
// player on the same lifecycle thread; it must not be reused.
bool airplay_player_prepare_restart(AirplayPlayer *);
// Enables copied playback telemetry at one-second intervals. Safe while playing.
void airplay_player_set_stats_enabled(AirplayPlayer *, bool enabled);
// Joins reception and playback before returning; no callbacks may follow.
void airplay_player_destroy(AirplayPlayer *);

#ifdef __cplusplus
}
#endif
