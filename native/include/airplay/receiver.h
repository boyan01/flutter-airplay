// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "player.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum AirplayVideoQuality {
    AIRPLAY_VIDEO_AUTO, AIRPLAY_VIDEO_720, AIRPLAY_VIDEO_1080, AIRPLAY_VIDEO_1440, AIRPLAY_VIDEO_2160
} AirplayVideoQuality;
typedef enum AirplayAudioOutput { AIRPLAY_AUDIO_AUTO, AIRPLAY_AUDIO_AAUDIO, AIRPLAY_AUDIO_AUDIOTRACK } AirplayAudioOutput;
typedef enum AirplayReceiverStatus {
    AIRPLAY_RECEIVER_STOPPED, AIRPLAY_RECEIVER_STARTING, AIRPLAY_RECEIVER_WAITING,
    AIRPLAY_RECEIVER_STREAMING, AIRPLAY_RECEIVER_STOPPING, AIRPLAY_RECEIVER_ERROR
} AirplayReceiverStatus;
typedef enum AirplaySettingFields {
    AIRPLAY_SETTING_NAME = 1 << 0, AIRPLAY_SETTING_PATH = 1 << 1,
    AIRPLAY_SETTING_VIDEO_QUALITY = 1 << 2, AIRPLAY_SETTING_AUDIO_OUTPUT = 1 << 3,
    AIRPLAY_SETTING_AUTO_START = 1 << 4, AIRPLAY_SETTING_FAST_PAIRING = 1 << 5,
    AIRPLAY_SETTING_LAUNCH_AT_LOGIN = 1 << 6, AIRPLAY_SETTING_KEEP_IN_MENU_BAR = 1 << 7,
    AIRPLAY_SETTING_SHOW_ON_CONNECT = 1 << 8, AIRPLAY_SETTING_FULLSCREEN_ON_CONNECT = 1 << 9,
    AIRPLAY_SETTING_ALWAYS_ON_TOP = 1 << 10, AIRPLAY_SETTING_PLAYBACK_STATS = 1 << 11,
    AIRPLAY_SETTING_PLAYBACK_BUFFER = 1 << 12, AIRPLAY_SETTINGS_ALL = (1 << 13) - 1
} AirplaySettingFields;
// Settings are copied before an asynchronous call returns. Lengths preserve
// embedded NULs for validation. fields permits native menus to update one option.
typedef struct {
    uint32_t fields;
    const char *name; size_t name_size;
    const char *path; size_t path_size;
    int32_t video_quality; // AirplayVideoQuality values, fixed-width C ABI.
    int32_t audio_output; // AirplayAudioOutput values.
    bool auto_start, fast_pairing, launch_at_login, keep_in_menu_bar;
    bool show_on_connect, fullscreen_on_connect, always_on_top;
    bool show_playback_stats;
    int32_t playback_buffer_ms; // 0=platform default, or 40, 60, 80, 100, 120, 150, 200, 300 ms.
} AirplayReceiverSettings;
typedef struct { int32_t width, height; } AirplayVideoSize;
typedef struct { int64_t id; const char *time, *text; } AirplayReceiverLog;
typedef struct {
    AirplayReceiverSettings settings, active_settings;
    int32_t status; // AirplayReceiverStatus values.
    const char *message, *client_name, *receiving_name, *default_name, *build_time, *platform;
    bool supports_executable_path, supports_launch_at_login, supports_aac_eld;
    bool is_television, native_video_surface, foreground_only;
    uint32_t video_quality_mask;
    int32_t screen_width, screen_height, auto_video_height, video_width, video_height;
    bool audio_playing, video_paused;
    uint64_t generation;
    int64_t pid, texture_id;
    const AirplayReceiverLog *logs; size_t log_count;
} AirplayReceiverSnapshot;
// The engine owns the receiver. Handles are checked in the shared registry;
// stale Dart isolates can never dereference a destroyed host or player.
typedef struct {
    void *context;
    // Lifecycle hooks run on the shared serial worker. Copy borrowed arguments
    // before dispatching to a platform main thread. No hook may wait for Dart.
    AirplayPlayer *(*create_player)(void *, AirplayCallbacks, int width, int height,
                                   int audio_mode, char *error, size_t capacity);
    void (*end_video)(void *, bool restarting);
    void (*clear_video)(void *);
    void (*frame)(void *, void *, int64_t deadline_ns);
    int64_t (*texture_id)(void *);
    // Return 1 after registration, 0 when awaiting asynchronous registration,
    // or -1 on failure. Async hosts call discovery with the supplied generation.
    int (*publish)(void *, uint64_t generation, const char *name,
                   const uint8_t *identity, uint16_t port,
                   const uint8_t *video_txt, size_t video_size,
                   const uint8_t *audio_txt, size_t audio_size,
                   char *error, size_t capacity);
    void (*unpublish)(void *);
    bool (*set_surface)(void *, AirplayPlayer *, void *surface);
    // Only platform preferences (for example login registration), never common
    // receiver settings. Dart persists first; failure leaves runtime settings
    // unchanged and the repository restores the previous persisted values.
    bool (*preferences)(void *, const char *settings, char *error, size_t capacity);
    bool (*check)(void *, char *error, size_t capacity);
    void (*event)(void *, const char *json);
    // Sample host output on the shared worker every five seconds and before stop.
    // Write a UTF-8 report, or leave the buffer empty when no output was observed.
    void (*diagnostics)(void *, char *output, size_t capacity);
} AirplayReceiverHost;

// metadata is a JSON object. identity/key_path identify this receiver.
// Dart owns settings persistence; this is a runtime copy.
uint64_t airplay_receiver_create(AirplayReceiverHost host, const char *metadata,
    const char *key_path,
    const uint8_t identity[6], char *error, size_t capacity);
void airplay_receiver_destroy(uint64_t handle);

void airplay_receiver_free_snapshot(AirplayReceiverSnapshot *snapshot);

// Native menus/lifecycle/tests may synchronously wait for the same worker.
// Snapshot ownership transfers to the caller. Other functions fill error on failure.
AirplayReceiverSnapshot *airplay_receiver_snapshot(uint64_t handle, char *error, size_t capacity);
bool airplay_receiver_save(uint64_t handle, const AirplayReceiverSettings *settings, char *error, size_t capacity);
bool airplay_receiver_start(uint64_t handle, uint64_t expected_generation, char *error, size_t capacity);
bool airplay_receiver_stop(uint64_t handle, char *error, size_t capacity);
bool airplay_receiver_disconnect(uint64_t handle, char *error, size_t capacity);
bool airplay_receiver_apply_settings(uint64_t handle, bool *applied, char *error, size_t capacity);
bool airplay_receiver_suspend(uint64_t handle, char *error, size_t capacity);
bool airplay_receiver_resume(uint64_t handle, char *error, size_t capacity);
bool airplay_receiver_check(uint64_t handle, const char *path, size_t path_size, char *error, size_t capacity);
bool airplay_receiver_requested_video_size(uint64_t handle, AirplayVideoSize *size, char *error, size_t capacity);
// Native Android lifecycle actions enqueue without waiting for Dart or main.
void airplay_receiver_request_start(uint64_t handle);
void airplay_receiver_request_stop(uint64_t handle);
void airplay_receiver_request_settings(uint64_t handle, const AirplayReceiverSettings *settings);

void airplay_receiver_discovery(uint64_t handle, uint64_t generation,
    bool ready, const char *error, const char *advertised_name);
bool airplay_receiver_set_surface(uint64_t handle, void *surface);
void airplay_receiver_update(uint64_t handle, const char *metadata);
void airplay_receiver_log(uint64_t handle, const char *message);
// Reports an asynchronous native output failure. The current session is checked
// again on the receiver worker so an obsolete failure cannot stop a new player.
void airplay_receiver_output_error(uint64_t handle, const char *message);

#ifdef __cplusplus
}
#endif
