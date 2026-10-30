// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../include/airplay/player.h"
#include "../protocol/uxplay_adapter.h"
#include "timeline.h"
#include <condition_variable>
#include <lychee/lychee.h>
#include <thread>
#include <vector>

// Experimental consumer of the public C ABI. UxPlay and its timestamps stay
// in this application; only codec configuration and access units cross it.
struct AirplayPlayer {
  AirplayCallbacks callbacks;
  std::atomic<bool> closing{false}, stats_enabled{false};
  std::unique_ptr<airplay::ProtocolAdapter> protocol;
  std::condition_variable wake;
  bool fast_pairing = true;
  int requested_width = 1920, requested_height = 1080;
#ifdef __APPLE__
  static constexpr int default_playback_buffer_ms = 120;
#else
  static constexpr int default_playback_buffer_ms = 80;
#endif
  AirplayPlayer(AirplayCallbacks, void *surface, const char *, const char *);
  ~AirplayPlayer();
  void receive_video(const uint8_t *, int size, int64_t local_pts);
  void receive_audio(const uint8_t *, int size, int ct, int64_t local_pts,
                     uint32_t rtp);
  void format_audio(uint8_t ct, uint16_t spf);
  void resize_video(float width, float height);
  void flush_audio();
  void stop_audio();
  void set_volume(float db);
  float volume_db() const { return volume.load(); }
  bool supports_hevc() const;
  int select_codec(bool hevc);
  void reset(const char *reason = "protocol_video_flush");
  void pause_video(bool paused);
  void log(const char *, int level = 6);
  void event(const char *type, const char *detail, int w = 0, int h = 0);
  bool set_buffer(int milliseconds);
  bool set_surface(void *surface);
  bool set_output(int mode);
  bool restore_volume(float db);
  bool hevc_supported = false;

private:
  void run();
  bool configure_audio_locked(int ct, int spf);
  void push_locked(int type, const uint8_t *, int size, int64_t pts_ns);
  // Hosts copy or retain the frame before the callback returns.
  void hand_off_locked(lychee_frame *, int64_t due_ns);
  lychee_player *live = nullptr;
  std::mutex lock; // Serializes protocol format/flush and frame handoff.
  std::thread worker;
  std::atomic<float> volume{-15.f};
  bool hevc = false, paused = false, video_declared = false,
       audio_playing = false;
  bool failed = false, rtp_anchored = false;
  uint32_t rtp_anchor = 0;
  int64_t rtp_pts = 0, latency_us = default_playback_buffer_ms * 1000;
  int audio_ct = 0;
  int width = 1920, height = 1080;
};
