// SPDX-License-Identifier: GPL-3.0-only
#include "player_internal.h"
#include <algorithm>
#include <cstdio>
#include <cmath>
#include <stdexcept>
#include <string>

using namespace airplay;

namespace {
// lychee logs through one process-wide callback, held by the newest player.
std::mutex log_lock;
AirplayPlayer *log_owner = nullptr;
void forward_log(void *player, int32_t level, const char *message) {
  static_cast<AirplayPlayer *>(player)->log(
      message, level <= LYCHEE_LOG_ERROR     ? 3
               : level == LYCHEE_LOG_WARNING ? 4
               : level == LYCHEE_LOG_INFO    ? 6
                                             : 7);
}
void hold_log(AirplayPlayer *player, bool hold) {
  std::lock_guard<std::mutex> guard(log_lock);
  if (hold || log_owner == player) {
    log_owner = hold ? player : nullptr;
    lychee_set_log_callback(hold ? forward_log : nullptr, log_owner);
  }
}
} // namespace

AirplayPlayer::AirplayPlayer(AirplayCallbacks cb, void *surface,
                             const AirplayVideoTexture *video)
    : callbacks(cb) {
  if (video)
    texture = *video;
  lychee_config config{};
  lychee_config_init(&config, sizeof(config));
#ifdef __APPLE__
  config.video_frame_types = LYCHEE_FRAME_CVPIXELBUFFER_NATIVE;
  static const bool hevc_ok = lychee_codec_supported(LYCHEE_CODEC_HEVC, 1) == 1;
#elif defined(__ANDROID__)
  // Android's Kotlin host chooses the HEVC decoder (set_hevc_decoder).
  config.video_frame_types = LYCHEE_FRAME_ANDROID_SURFACE;
  constexpr bool hevc_ok = false;
#else
  // FFmpeg (Linux) and Media Foundation (Windows) answer for any decoder.
  config.video_frame_types = LYCHEE_FRAME_CPU_RGBA;
  static const bool hevc_ok = lychee_codec_supported(LYCHEE_CODEC_HEVC, 0) == 1;
#endif
  hevc_supported = hevc_ok;
  if (texture.bind)
    config.video_frame_types = texture.frame_types;
  hold_log(this, true);
  try {
    live = lychee_player_create(&config);
    if (!live)
      throw std::runtime_error("Cannot create lychee player");
    if (!set_surface(surface) || !set_buffer(0))
      throw std::runtime_error("Cannot open lychee live input");
    lychee_player_set_volume(live, std::pow(10.f, volume.load() / 20.f));
    lychee_player_set_event_callback(
        live,
        [](void *player, int32_t type, int64_t, int64_t) {
          if (type != LYCHEE_EVENT_ERROR)
            return;
          auto *self = static_cast<AirplayPlayer *>(player);
          char error[512]{};
          lychee_player_get_error(self->live, error, sizeof(error));
          self->log(error, 3);
          self->event("error", error);
        },
        this);
    protocol = std::make_unique<ProtocolAdapter>(*this);
    worker = std::thread([this] { run(); });
  } catch (...) {
    if (live)
      lychee_player_destroy(live);
    hold_log(this, false);
    throw;
  }
  if (texture.bind)
    texture.bind(texture.context, live);
  log("Playback backend: lychee live C ABI");
}
AirplayPlayer::~AirplayPlayer() {
  closing = true;
  wake.notify_all();
  if (protocol)
    protocol->stop_receiver();
  if (worker.joinable())
    worker.join();
  if (texture.bind)
    texture.bind(texture.context, nullptr);
  hold_log(this, false);
  lychee_player_destroy(live);
}
void AirplayPlayer::log(const char *text, int level) {
  if (!closing && callbacks.log)
    callbacks.log(callbacks.context, level, text);
}
void AirplayPlayer::event(const char *type, const char *detail, int w, int h) {
  if (!closing && callbacks.event)
    callbacks.event(callbacks.context, type, detail, w, h);
}
bool AirplayPlayer::set_buffer(int milliseconds) {
  if ((protocol && protocol->started()) ||
      (milliseconds != 0 && milliseconds != 40 && milliseconds != 60 &&
       milliseconds != 80 && milliseconds != 100 && milliseconds != 120 &&
       milliseconds != 150 && milliseconds != 200 && milliseconds != 300))
    return false;
  lychee_live_config config{};
  config.struct_size = sizeof(config);
  config.latency_us = latency_us =
      int64_t(milliseconds ? milliseconds : default_playback_buffer_ms) * 1000;
  return lychee_player_open_live(live, &config) == 0;
}
bool AirplayPlayer::set_surface(void *surface) {
#ifdef __ANDROID__
  if (!surface)
    return false;
  lychee_player_set_video_surface(live, surface);
  return true;
#else
  (void)surface;
  return true;
#endif
}
bool AirplayPlayer::set_output(int mode) {
  // lychee owns AAudio; preserve explicit AudioTrack requests
  // as an error instead of silently using a different requested backend.
  if (mode == 2) {
    log("Lychee live currently supports Auto/AAudio output only");
    return false;
  }
  return mode == 0 || mode == 1;
}
void AirplayPlayer::push_locked(int type, const uint8_t *bytes, int size,
                                int64_t pts_ns) {
  lychee_live_packet packet{};
  packet.struct_size = sizeof(packet);
  packet.type = type;
  packet.data = bytes;
  packet.size = size;
  // UxPlay reports local NTP times in nanoseconds for both streams. Do not
  // apply this application's old Timeline again: lychee owns the mapping.
  packet.pts_us = pts_ns / 1000;
  if (lychee_player_push_live_packet(live, &packet))
    log("Lychee live rejected a packet", 4);
}
void AirplayPlayer::receive_video(const uint8_t *bytes, int size, int64_t pts) {
  if (closing || !bytes || size < 5 || size > 4 * 1024 * 1024)
    return;
  std::lock_guard<std::mutex> guard(lock);
  if (!video_declared) {
    lychee_live_track track{};
    track.struct_size = sizeof(track);
    track.type = LYCHEE_TRACK_VIDEO;
    track.codec = hevc ? LYCHEE_CODEC_HEVC : LYCHEE_CODEC_H264;
    track.width = width;
    track.height = height;
    if (lychee_player_set_live_track(live, &track)) {
      log("Cannot declare lychee video track", 3);
      return;
    }
    video_declared = true;
  }
  push_locked(LYCHEE_TRACK_VIDEO, bytes, size, pts ? pts : realtime_ns());
}
bool AirplayPlayer::configure_audio_locked(int ct, int spf) {
  if (ct != 2 && ct != 4 && ct != 8)
    return false;
  if (spf <= 0)
    spf = ct == 2 ? 352 : ct == 4 ? 1024 : 480;
  if ((ct == 4 && spf != 960 && spf != 1024) ||
      (ct == 8 && spf != 480 && spf != 512) || spf > 16384)
    return false;
  std::vector<uint8_t> cookie;
  if (ct == 2) {
    cookie = {uint8_t(spf >> 24),
              uint8_t(spf >> 16),
              uint8_t(spf >> 8),
              uint8_t(spf),
              0,
              16,
              40,
              10,
              14,
              2,
              0,
              255,
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              0xac,
              0x44};
  } else if (ct == 8) {
    // ISO 14496-3 ASC: escaped AOT 39, 44100 Hz, stereo,
    // frameLengthFlag (480 or 512), no SBR and no ELD extensions.
    cookie = {0xf8, 0xe8, uint8_t(spf == 512 ? 0x40 : 0x50), 0};
  } else {
    cookie = {0x12, uint8_t(spf == 960 ? 0x14 : 0x10)};
  }
  lychee_live_track track{};
  track.struct_size = sizeof(track);
  track.type = LYCHEE_TRACK_AUDIO;
  track.codec = ct == 2 ? LYCHEE_CODEC_ALAC : LYCHEE_CODEC_AAC;
  track.sample_rate = kSampleRate;
  track.channels = 2;
  track.config = cookie.data();
  track.config_size = int(cookie.size());
  if (lychee_player_set_live_track(live, &track))
    return false;
  audio_ct = ct;
  rtp_anchored = false;
  log(ct == 8   ? "Lychee live audio: AAC-ELD"
      : ct == 4 ? "Lychee live audio: AAC"
                : "Lychee live audio: ALAC");
  return true;
}
void AirplayPlayer::format_audio(uint8_t ct, uint16_t spf) {
  std::lock_guard<std::mutex> guard(lock);
  if (!configure_audio_locked(ct, spf))
    log("Lychee live rejected audio format", 3);
}
void AirplayPlayer::receive_audio(const uint8_t *bytes, int size, int ct,
                                  int64_t pts, uint32_t rtp) {
  if (closing || !bytes || size <= 0 || size > 65536)
    return;
  std::lock_guard<std::mutex> guard(lock);
  if (ct != audio_ct && !configure_audio_locked(ct, 0))
    return;
  if (!pts)
    pts = rtp_anchored ? rtp_pts + int64_t(int32_t(rtp - rtp_anchor)) *
                                       kSecond / kSampleRate
                       : realtime_ns();
  rtp_anchored = true;
  rtp_anchor = rtp;
  rtp_pts = pts;
  push_locked(LYCHEE_TRACK_AUDIO, bytes, size, pts);
}
void AirplayPlayer::resize_video(float w, float h) {
  if (w < 1 || h < 1 || w > 4096 || h > 4096)
    return;
  {
    std::lock_guard<std::mutex> guard(lock);
    width = int(w);
    height = int(h);
  }
  event("size", "Video dimensions", int(w), int(h));
}
void AirplayPlayer::flush_audio() {
  std::lock_guard<std::mutex> guard(lock);
  lychee_player_flush_live(live, LYCHEE_TRACK_AUDIO);
  rtp_anchored = false;
  if (audio_playing) {
    audio_playing = false;
    event("audio_stopped", "Audio paused");
  }
}
void AirplayPlayer::stop_audio() {
  std::lock_guard<std::mutex> guard(lock);
  lychee_live_track track{};
  track.struct_size = sizeof(track);
  track.type = LYCHEE_TRACK_AUDIO;
  lychee_player_set_live_track(live, &track);
  audio_ct = 0;
  rtp_anchored = false;
  if (audio_playing) {
    audio_playing = false;
    event("audio_stopped", "Audio stopped");
  }
}
void AirplayPlayer::reset(const char *reason) {
  std::lock_guard<std::mutex> guard(lock);
  if (lychee_player_get_state(live) == LYCHEE_STATE_ERROR) {
    lychee_live_config config{};
    config.struct_size = sizeof(config);
    config.latency_us = latency_us;
    lychee_player_open_live(live, &config);
    video_declared = false;
    audio_ct = 0;
  } else {
    lychee_player_flush_live(live, 0);
  }
  rtp_anchored = false;
  paused = false;
  audio_playing = false;
  log((std::string("Lychee live reset: ") + reason).c_str());
  event("reset", "Waiting for screen mirroring");
}
void AirplayPlayer::pause_video(bool value) {
  std::lock_guard<std::mutex> guard(lock);
  paused = value;
  if (paused)
    event("paused", "Video paused; audio continues");
}
int AirplayPlayer::select_codec(bool value) {
  std::lock_guard<std::mutex> guard(lock);
  if (value && !supports_hevc())
    return -1;
  if (value != hevc) {
    hevc = value;
    video_declared = false;
    lychee_player_flush_live(live, LYCHEE_TRACK_VIDEO);
  }
  return 0;
}
void AirplayPlayer::set_volume(float db) {
  if (!airplay_player_set_volume(this, db))
    return;
  event("volume", std::to_string(db).c_str());
}
bool AirplayPlayer::present_locked(int64_t now, int &w, int &h) {
  if (!lychee_player_has_new_frame(live, now))
    return false;
  auto *frame = lychee_player_acquire_frame(live, now);
  if (!frame)
    return false;
  w = lychee_frame_get_width(frame);
  h = lychee_frame_get_height(frame);
#ifdef __APPLE__
  if (callbacks.frame) {
    // Convert epochs at handoff; the host's monotonic clock need not be
    // lychee_now_us()'s (mach_absolute_time() on Apple).
    const auto due =
        monotonic_ns() + (lychee_frame_get_pts(frame) - lychee_now_us()) * 1000;
    callbacks.frame(callbacks.context, lychee_frame_get_native_handle(frame),
                    due);
  }
#endif
  lychee_frame_release(frame);
  return true;
}
void AirplayPlayer::report_stats_locked(const lychee_stats &stats,
                                        int64_t interval_us, int64_t rendered) {
  char text[768];
  std::snprintf(
      text, sizeof(text),
      "{\"codec\":\"%s\",\"videoDecoder\":\"%s\",\"hardware\":%s,"
      "\"audioDecoder\":\"%s\",\"fps\":%.1f,\"dropped\":%lld,"
      "\"packetsDropped\":%lld,\"audioLateMs\":%lld,\"audioSilenceMs\":%lld,"
      "\"audioBehindMs\":%lld,\"videoBufferedMs\":%lld,"
      "\"audioBufferedMs\":%lld}",
      hevc ? "HEVC" : "H.264", stats.video_decoder,
      stats.hardware_decoding ? "true" : "false", stats.audio_decoder,
      double(rendered) * 1000000 / double(std::max<int64_t>(interval_us, 1)),
      static_cast<long long>(stats.frames_dropped),
      static_cast<long long>(stats.live_video_packets_dropped),
      static_cast<long long>(stats.live_audio_late_us / 1000),
      static_cast<long long>(stats.live_audio_silence_us / 1000),
      static_cast<long long>(stats.live_audio_behind_us / 1000),
      static_cast<long long>(stats.video_buffered_us / 1000),
      static_cast<long long>(stats.audio_buffered_us / 1000));
  event("playbackStats", text);
}
void AirplayPlayer::run() {
  auto report = lychee_now_us();
  int64_t reported_frames = 0, shown_frames = 0;
  while (!closing) {
    std::unique_lock<std::mutex> guard(lock);
    const auto now = lychee_now_us();
    lychee_stats stats{};
    stats.struct_size = sizeof(stats);
    lychee_player_get_stats(live, &stats);
    if (!audio_playing && audio_ct && stats.audio_buffered_us > 0) {
      audio_playing = true;
      event("audio", "Decoded audio ready");
    }
    // A texture pulls frames itself: a newly rendered one means playing. A
    // new video renderer counts from zero. Otherwise acquire here; pausing must
    // prevent that, which submits Android's MediaCodec buffer to the Surface.
    int w = 0, h = 0;
    bool playing = false;
    if (texture.bind) {
      playing = !paused && stats.frames_rendered != shown_frames;
      shown_frames = stats.frames_rendered;
      if (playing)
        lychee_player_get_video_size(live, &w, &h);
    } else if (!paused) {
      playing = present_locked(now, w, h);
    }
    if (playing && w > 0 && h > 0)
      event("playing", "Lychee decoded video ready", w, h);
    if (now - report >= 1000000) {
      if (stats_enabled)
        report_stats_locked(stats, now - report,
                            stats.frames_rendered >= reported_frames
                                ? stats.frames_rendered - reported_frames
                                : stats.frames_rendered);
      reported_frames = stats.frames_rendered;
      report = now;
    }
    // Polling only wakes the existing host display path; the core owns
    // cadence selection. No second clock or decoded-frame queue here.
    wake.wait_for(guard, std::chrono::microseconds(8333),
                  [this] { return closing.load(); });
  }
}
extern "C" AirplayPlayer *airplay_player_create(AirplayCallbacks cb,
                                                void *surface,
                                                const AirplayVideoTexture *texture) {
  try {
    return new AirplayPlayer(cb, surface, texture);
  } catch (...) {
    return nullptr;
  }
}
extern "C" void airplay_player_destroy(AirplayPlayer *p) { delete p; }
extern "C" bool airplay_player_set_video_size(AirplayPlayer *p, int w, int h) {
  if (!p || p->protocol->started() || w < 1 || h < 1 || w > 4096 || h > 4096)
    return false;
  p->requested_width = w;
  p->requested_height = h;
  return true;
}
extern "C" bool airplay_player_set_playback_buffer(AirplayPlayer *p, int ms) {
  return p && p->set_buffer(ms);
}
extern "C" bool airplay_player_set_fast_pairing(AirplayPlayer *p,
                                                bool enabled) {
  if (!p || p->protocol->started())
    return false;
  p->fast_pairing = enabled;
  return true;
}
bool AirplayPlayer::restore_volume(float db) {
  if (!std::isfinite(db) || (db != -144.f && (db < -30.f || db > 0.f)))
    return false;
  volume = db;
  lychee_player_set_volume(live, db <= -144 ? 0 : std::pow(10.f, db / 20.f));
  return true;
}
extern "C" bool airplay_player_set_volume(AirplayPlayer *p, float db) {
  return p && p->restore_volume(db);
}
extern "C" bool airplay_player_start(AirplayPlayer *p, const char *name,
                                     const uint8_t id[6], const char *key,
                                     char *error, size_t size) {
  return p && p->protocol->start(name, id, key, error, size);
}
extern "C" uint16_t airplay_player_port(AirplayPlayer *p) {
  return p ? p->protocol->port() : 0;
}
extern "C" size_t airplay_player_txt(AirplayPlayer *p, bool audio, uint8_t *out,
                                     size_t size) {
  return p ? p->protocol->txt(audio, out, size) : 0;
}
extern "C" bool airplay_player_prepare_restart(AirplayPlayer *p) {
  return p && p->protocol->prepare_restart();
}
extern "C" void airplay_player_set_stats_enabled(AirplayPlayer *p,
                                                 bool enabled) {
  if (p)
    p->stats_enabled = enabled;
}
#ifdef __ANDROID__
extern "C" bool airplay_player_set_surface(AirplayPlayer *p, void *surface) {
  return p && p->set_surface(surface);
}
extern "C" bool airplay_player_set_audio_output(AirplayPlayer *p, int mode) {
  return p && !p->protocol->started() && p->set_output(mode);
}
extern "C" bool airplay_player_set_hevc_decoder(AirplayPlayer *p,
                                                const char *name) {
  if (!p || p->protocol->started() || !name)
    return false;
  p->hevc_supported = *name;
  return true;
}
#endif
