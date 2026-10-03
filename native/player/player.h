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
// frame is a borrowed CVPixelBuffer on macOS; Android renders directly to Surface.
// Media events: playing carries decoded video dimensions; paused hides video
// until a fresh playing event; audio marks queued PCM; audio_stopped clears it.
// reset clears both media states; waiting ends the sender session.
typedef struct {
    void *context;
    void (*event)(void *, const char *type, const char *detail, int width, int height);
    void (*frame)(void *, void *frame);
    void (*log)(void *, int level, const char *message);
} AirplayCallbacks;

// surface is a borrowed ANativeWindow on Android; create retains its own reference.
// It is unused on macOS.
AirplayPlayer *airplay_player_create(AirplayCallbacks callbacks, void *surface,
                                    const char *decoder, const char *fallback);
bool airplay_player_start(AirplayPlayer *, const char *name, const uint8_t identity[6],
                          const char *key_path, char *error, size_t error_size);
uint16_t airplay_player_port(AirplayPlayer *);
size_t airplay_player_txt(AirplayPlayer *, bool audio, uint8_t *output, size_t capacity);
// Joins reception and playback before returning; no callbacks may follow.
void airplay_player_destroy(AirplayPlayer *);

#ifdef __cplusplus
}
#endif
