// SPDX-License-Identifier: GPL-3.0-only
// Feed production UxPlay callback bindings, without requiring a phone sender.
#include "../../playback/player_internal.h"
#include "../../protocol/uxplay_callbacks.h"
#include "../fixtures/resume_fixtures.h"
#ifdef __APPLE__
#include "apple_pixels.h"
#endif
#include <fstream>
#include <stdexcept>

using namespace airplay;

std::string check_lychee_live(void *surface, const char *audio_path) {
  struct Progress {
    std::atomic<int> frames{0}, audio{0}, errors{0}, pauses{0};
    std::atomic<bool> blue{false};
  } progress;
  AirplayCallbacks cb{};
  cb.context = &progress;
  cb.event = [](void *context, const char *type, const char *, int, int) {
    auto &p = *static_cast<Progress *>(context);
    if (!strcmp(type, "playing"))
      ++p.frames;
    if (!strcmp(type, "audio"))
      ++p.audio;
    if (!strcmp(type, "error"))
      ++p.errors;
    if (!strcmp(type, "paused"))
      ++p.pauses;
  };
  cb.log = [](void *, int, const char *text) {
    std::fprintf(stderr, "%s\n", text);
  };
#ifdef __APPLE__
  cb.frame = [](void *context, void *frame, int64_t) {
    const auto pixel = apple_rgb(static_cast<CVPixelBufferRef>(frame));
    if (pixel[2] > 200 && pixel[1] < 30 && pixel[0] < 30)
      static_cast<Progress *>(context)->blue = true;
  };
#endif
  auto *player = airplay_player_create(cb, surface, "", "");
  if (!player)
    throw std::runtime_error("cannot create lychee backend");
  const auto receive = receiver_callbacks(player);
  try {
    if (!airplay_player_set_playback_buffer(player, 120) ||
        !airplay_player_set_volume(player, -7.5f) ||
        receive.audio_set_client_volume(receive.cls) != -7.5)
      throw std::runtime_error("buffer/volume restoration failed");
    if (!airplay_player_set_volume(player, -144.f))
      throw std::runtime_error("mute failed");
    float w = 640, h = 360;
    receive.video_report_size(receive.cls, &w, &h, nullptr, nullptr);
    unsigned char ct = 8;
    unsigned short spf = 512;
    receive.audio_get_format(receive.cls, &ct, &spf, nullptr, nullptr, nullptr);
    std::ifstream input(audio_path, std::ios::binary);
    if (!input)
      throw std::runtime_error("missing raw AAC-ELD packets");
    const auto start = monotonic_ns(), pts = realtime_ns();
    int video_sent = 0, audio_sent = 0, paused_frames = -1;
    bool resumed = false;
    while (monotonic_ns() - start < 3200000000LL) {
      const auto elapsed = monotonic_ns() - start;
      const auto video_time = video_sent * kSecond / 30;
      // Warm MediaCodec with enough red IDRs before the continuous red-to-blue
      // GOP. Sparse input otherwise leaves the emulator's decoder buffering.
      if (video_sent < 38 && elapsed >= video_time) {
        const int index = video_sent < 30 ? 0 : video_sent - 29;
        if (index == 3) {
          receive.video_pause(receive.cls);
          paused_frames = progress.frames;
        }
        video_decode_struct data{};
        data.data = const_cast<uint8_t *>(resume_frames[index]);
        data.data_len = int(resume_sizes[index]);
        data.ntp_time_local = pts + video_time;
        receive.video_process(receive.cls, nullptr, &data);
        ++video_sent;
      }
      if (!resumed && elapsed >= 2200000000LL) {
        if (progress.frames != paused_frames)
          throw std::runtime_error(
              "paused player still presents decoded video");
        receive.video_resume(receive.cls);
        resumed = true;
      }
      if (input &&
          elapsed >= int64_t(audio_sent) * spf * kSecond / kSampleRate) {
        uint8_t header[4]{};
        input.read(reinterpret_cast<char *>(header), 4);
        if (input) {
          const uint32_t size = uint32_t(header[0]) << 24 |
                                uint32_t(header[1]) << 16 |
                                uint32_t(header[2]) << 8 | header[3];
          if (!size || size > 65536)
            throw std::runtime_error("bad audio fixture size");
          std::vector<uint8_t> packet(size);
          input.read(reinterpret_cast<char *>(packet.data()), size);
          if (!input)
            throw std::runtime_error("truncated audio fixture");
          audio_decode_struct data{};
          data.data = packet.data();
          data.data_len = int(size);
          data.ct = ct;
          data.rtp_time = uint32_t(audio_sent * spf);
          // Exercise the RTP fallback after the first synchronized packet.
          data.ntp_time_local = audio_sent ? 0 : pts;
          receive.audio_process(receive.cls, nullptr, &data);
          ++audio_sent;
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (progress.frames < 3 || !progress.audio || progress.errors ||
        progress.pauses != 1)
      throw std::runtime_error(
          "missing decoded video/audio or pause transition");
#ifdef __APPLE__
    if (!progress.blue)
      throw std::runtime_error("resume lost inter-frame blue pixels");
#endif
    receive.audio_flush(receive.cls);
    receive.audio_stop(receive.cls);
    receive.video_flush(receive.cls);
    std::printf("summary: backend=lychee video=%d audio=%d packets=%d "
                "pauses=%d errors=%d\n",
                progress.frames.load(), progress.audio.load(), audio_sent,
                progress.pauses.load(), progress.errors.load());
  } catch (...) {
    airplay_player_destroy(player);
    throw;
  }
  airplay_player_destroy(player);
  return "PASS: production callbacks through lychee live; summary: video=" +
         std::to_string(progress.frames.load()) +
         " audio=" + std::to_string(progress.audio.load()) +
         " pauses=" + std::to_string(progress.pauses.load()) +
         " errors=" + std::to_string(progress.errors.load());
}
#ifdef __ANDROID__
#include <android/native_window_jni.h>
#include <jni.h>
extern "C" JNIEXPORT jstring JNICALL
Java_tech_soit_flutterairplay_live_1regression_TestActivity_run(JNIEnv *env,
                                                                jobject,
                                                                jobject surface,
                                                                jstring path) {
  auto *window = ANativeWindow_fromSurface(env, surface);
  const auto *file = env->GetStringUTFChars(path, nullptr);
  std::string result = "PASS: production callbacks through lychee live";
  try {
    result = check_lychee_live(window, file);
  } catch (const std::exception &error) {
    result = std::string("FAIL: ") + error.what();
  }
  env->ReleaseStringUTFChars(path, file);
  ANativeWindow_release(window);
  return env->NewStringUTF(result.c_str());
}
#else
int main(int argc, char **argv) {
  try {
    if (argc != 2)
      throw std::runtime_error("usage: lychee_live_tests RAW_PACKETS");
    std::puts(check_lychee_live(nullptr, argv[1]).c_str());
    std::puts("PASS: production callbacks, AAC-ELD, pixels, pause/resume, "
              "flush and teardown");
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "FAIL: %s\n", error.what());
    return 1;
  }
}
#endif
