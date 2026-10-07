// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "platform.h"
#include "audio_decoder.h"
#include "timing_stats.h"
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#ifdef __ANDROID__
#include "../backends/android/android_audio.h"
#endif
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <thread>
#include <string>
#include "../protocol/uxplay_adapter.h"
using namespace airplay;
struct AirplayPlayer {
    AirplayCallbacks callbacks;
    std::atomic<bool> closing{false}, stats_enabled{false};
    std::unique_ptr<airplay::ProtocolAdapter> protocol;
#if defined(__APPLE__) && TARGET_OS_OSX
    // Cover short TCP arrival stalls without changing relative audio/video time.
    Timeline timeline{120000000};
#else
    Timeline timeline;
#endif
    std::shared_ptr<AudioBuffer> pcm = std::make_shared<AudioBuffer>();
    AudioDecoder audio;
    std::unique_ptr<AudioOutput> output;
    std::unique_ptr<VideoOutput> video;
    std::mutex lock;
    std::condition_variable wake;
    std::deque<VideoPacket> packets;
    std::thread worker;
    uint64_t video_generation = 1;
    bool video_reset = false;
    bool video_paused = false;
    bool video_hevc = false;
    bool fast_pairing = true;
    bool audio_playing = false;
    uint8_t audio_ct = 0;
    bool audio_rtp_anchored = false;
    uint32_t audio_rtp_anchor = 0;
    int64_t audio_rtp_local_pts = 0;
    int width = 1920, height = 1080;
    int requested_width = 1920, requested_height = 1080;
    size_t queued_bytes = 0;
    // Protected by lock; receive counts are compressed callback packets, not display frames.
    int64_t video_report_ns = 0, video_arrival_ns = 0, video_gap_ns = 0;
    uint64_t video_received = 0;
    size_t video_peak_queue = 0;
    struct VideoStats {
        uint64_t ready = 0, submitted = 0, late_drop = 0, cancelled = 0, nonpositive_pts_step = 0;
        TimingSamples queue_wait, ready_late, submit_late, submit_gap, pts_gap, host_call;
    } video_stats;
    int64_t last_video_submit = 0, last_video_due = 0, video_stats_started = 0;
    int64_t last_video_decode = 0, last_video_output = 0;
    int64_t video_no_output_started = 0;
    std::atomic<uint64_t> audio_packets{0}, audio_bytes{0}, audio_decode_errors{0}, audio_pcm_packets{0}, audio_timestamp_rejects{0}, audio_timestamp_fallbacks{0};
    std::atomic<int64_t> audio_lead_ms{0};

    AirplayPlayer(AirplayCallbacks cb, void *surface, const char *decoder, const char *fallback)
        : callbacks(cb), audio(pcm, [this](const char *text) { log(text); }) {
        output = make_audio_output(pcm);
        video = make_video_output(surface, decoder, fallback, {
            [this](void *frame, int w, int h, int64_t due, uint64_t generation) {
                // The shared scheduler releases pictures; never block decoding on PTS here.
                std::unique_lock<std::mutex> guard(lock);
                if (closing || video_paused || generation != video_generation) return;
                const auto ready = monotonic_ns();
                if (frame) { ++video_stats.ready; video_stats.ready_late.add(ready - due); }
                const auto submitted = monotonic_ns();
                if (closing || video_paused || generation != video_generation) {
                    if (frame) ++video_stats.cancelled;
                    return;
                }
                if (due < submitted - kVideoLateToleranceNs) {
                    if (frame) ++video_stats.late_drop;
                    return;
                }
                // Android presents directly to Surface and reports a null
                // frame; output progress must not depend on a Flutter texture.
                last_video_output = submitted;
                video_no_output_started = 0;
                if (frame && callbacks.frame) {
                    ++video_stats.submitted;
                    video_stats.submit_late.add(submitted - due);
                    if (last_video_submit) video_stats.submit_gap.add(submitted - last_video_submit);
                    if (last_video_due) {
                        if (due <= last_video_due) ++video_stats.nonpositive_pts_step;
                        else video_stats.pts_gap.add(due - last_video_due);
                    }
                    last_video_submit = submitted; last_video_due = due;
                    callbacks.frame(callbacks.context, frame);
                    video_stats.host_call.add(monotonic_ns() - submitted);
                }
                event("playing", "Decoded video ready", w, h);
            }, [this](const char *text) { log(text); }
        });
        protocol = std::make_unique<ProtocolAdapter>(*this);
        worker = std::thread([this] { run(); });
    }
    ~AirplayPlayer() {
        closing = true; wake.notify_all();
        if (protocol) protocol->stop_receiver(); // joins all network callbacks first
        if (worker.joinable()) worker.join();
        video.reset();
        output->stop(); output.reset();
        protocol.reset();
    }
    void log(const char *text, int level = 6 /* syslog LOG_INFO */) {
        if (!closing && callbacks.log) callbacks.log(callbacks.context, level, text);
    }
    void event(const char *type, const char *detail, int w = 0, int h = 0) {
        if (!closing && callbacks.event) callbacks.event(callbacks.context, type, detail, w, h);
    }
    int64_t audio_pts(int64_t local_pts, uint32_t rtp) {
        std::lock_guard<std::mutex> guard(lock);
        if (!local_pts) {
            ++audio_timestamp_fallbacks;
            // Packet arrival can be bursty even when the sender's sample clock is continuous.
            local_pts = audio_rtp_anchored
                ? audio_rtp_local_pts + int64_t(int32_t(rtp - audio_rtp_anchor)) * kSecond / kSampleRate
                : realtime_ns();
        }
        audio_rtp_anchored = true; audio_rtp_anchor = rtp; audio_rtp_local_pts = local_pts;
        return local_pts;
    }
    void reset() {
        { std::lock_guard<std::mutex> guard(lock);
          ++video_generation; packets.clear(); queued_bytes = 0; video_reset = true;
          video_paused = false;
          video_stats = {}; last_video_submit = last_video_due = video_stats_started = 0;
          last_video_decode = last_video_output = 0;
          video_no_output_started = 0;
          video_report_ns = video_arrival_ns = video_gap_ns = 0;
          video_received = 0; video_peak_queue = 0;
          audio_playing = false; audio_ct = 0; audio_rtp_anchored = false;
          timeline.reset(); audio.flush();
          event("reset", "Waiting for screen mirroring"); }
        wake.notify_all();
    }
    void pause_video(bool paused) {
        { std::lock_guard<std::mutex> guard(lock);
          video_paused = paused;
          // A sender pause can resume within the same H.264 GOP. Keep decoder
          // references, queued input, continuing audio and the shared clock.
          if (paused) event("paused", "Video paused; waiting for sender"); }
        wake.notify_all();
    }
    void run() {
        uint64_t generation = 1;
        auto next_audio_report = monotonic_ns() + 5 * kSecond;
        auto profile_at = monotonic_ns();
        VideoScheduler::Stats profile_previous{}, profile_base{};
        while (!closing) {
            VideoPacket packet;
            int w, h;
            bool reset;
            // A fixed poll can release consecutive 60 FPS frames on opposite sides
            // of a display refresh. Wake for held output instead of adding 0-5 ms
            // of presentation jitter; new packets and shutdown still wake early.
            const auto deadline = video->next_deadline();
            const bool can_decode = video->can_decode();
            const auto wait_ns = deadline ? std::clamp<int64_t>(deadline - monotonic_ns(), 0, 5000000) : 5000000;
            { std::unique_lock<std::mutex> guard(lock);
              wake.wait_for(guard, std::chrono::nanoseconds(wait_ns), [&] { return closing || video_reset || (can_decode && !packets.empty()); });
              if (closing) break;
              reset = video_reset; video_reset = false; generation = video_generation; w = width; h = height;
              if ((reset || can_decode) && !packets.empty()) { packet = std::move(packets.front()); packets.pop_front(); queued_bytes -= packet.bytes.size();
                  last_video_decode = monotonic_ns();
                  if (!video_no_output_started) video_no_output_started = last_video_decode;
                  if (!video_stats_started) video_stats_started = monotonic_ns();
                  if (packet.received_ns) video_stats.queue_wait.add(monotonic_ns() - packet.received_ns);
              } }
            if (reset) {
                video->reset();
                profile_base = profile_previous = video->stats();
                profile_at = monotonic_ns();
            }
            video->size(w, h);
            if (!packet.bytes.empty() && packet.generation == generation && !video->decode(packet)) {
                video->reset(); event("error", "Video decoding failed; reconnect screen mirroring");
            }
            video->drain();
            const auto now = monotonic_ns();
            report_video(now);
            // Sample scheduler state before taking the player lock: Apple frame
            // callbacks can take the player lock while retiring scheduler leases.
            if (now - profile_at >= kSecond) {
                const auto stats = video->stats();
                std::lock_guard<std::mutex> guard(lock);
                if (stats_enabled && generation == video_generation && video_arrival_ns && !video_paused) {
                    char profile[512];
                    std::snprintf(profile, sizeof(profile),
                        "{\"codec\":\"%s\",\"decoder\":\"%s\",\"fps\":%.2f,\"submitted\":%llu,\"dropped\":%llu,\"pending\":%zu,\"queued\":%zu,\"audioCodec\":\"%s\",\"audioSampleRate\":%d,\"audioChannels\":%d}",
                        video_hevc ? "HEVC" : "H.264", video->decoder_name(),
                        (stats.submitted - profile_previous.submitted) * 1e9 / (now - profile_at),
                        static_cast<unsigned long long>(stats.submitted - profile_base.submitted),
                        static_cast<unsigned long long>(stats.dropped - profile_base.dropped),
                        stats.pending, packets.size(),
                        audio_playing ? (audio_ct == 2 ? "ALAC" : audio_ct == 4 ? "AAC" : audio_ct == 8 ? "AAC-ELD" : "") : "",
                        audio_playing ? kSampleRate : 0, audio_playing ? 2 : 0);
                    event("playbackStats", profile);
                }
                profile_previous = stats; profile_at = now;
            }
            if (now >= next_audio_report) {
                next_audio_report = now + 5 * kSecond;
                if (protocol->connections() > 0) {
                    char message[512];
                    std::snprintf(message, sizeof(message),
                        "Audio receive totals: packets=%llu bytes=%llu decode_errors=%llu pcm_packets=%llu timestamp_rejects=%llu timestamp_fallbacks=%llu last_lead_ms=%lld",
                        static_cast<unsigned long long>(audio_packets.load()), static_cast<unsigned long long>(audio_bytes.load()),
                        static_cast<unsigned long long>(audio_decode_errors.load()), static_cast<unsigned long long>(audio_pcm_packets.load()),
                        static_cast<unsigned long long>(audio_timestamp_rejects.load()),
                        static_cast<unsigned long long>(audio_timestamp_fallbacks.load()), static_cast<long long>(audio_lead_ms.load()));
                    log(message);
                    const auto output_report = output->diagnostics();
                    if (!output_report.empty()) log(output_report.c_str());
                }
            }
        }
        video->reset();
    }
    void format_audio(uint8_t ct, uint16_t spf);
    void resize_video(float width, float height);
    void flush_audio();
    void set_volume(float db);
    int select_codec(bool hevc);
    void receive_video(const uint8_t* bytes, int size, int64_t local_pts);
    void receive_audio(const uint8_t* bytes, int size, int ct, int64_t local_pts, uint32_t rtp);
    void report_video(int64_t now) {
        std::string message, stall;
        const auto *decoder = video->decoder_name();
        {
            std::lock_guard<std::mutex> guard(lock);
            if (!video_stats_started || now - video_stats_started < 5 * kSecond) return;
            char counts[320];
            std::snprintf(counts, sizeof(counts),
                "Video submit stats: interval_ms=%lld ready=%llu submitted=%llu late_drop=%llu cancelled=%llu nonpositive_pts_step=%llu queued=%zu",
                static_cast<long long>((now - video_stats_started) / 1000000),
                static_cast<unsigned long long>(video_stats.ready), static_cast<unsigned long long>(video_stats.submitted),
                static_cast<unsigned long long>(video_stats.late_drop), static_cast<unsigned long long>(video_stats.cancelled),
                static_cast<unsigned long long>(video_stats.nonpositive_pts_step), packets.size());
            if (video_stats.queue_wait.count || video_stats.ready) {
                message = std::string(counts) + video_stats.queue_wait.text("queue_wait") + video_stats.ready_late.text("ready_late")
                    + video_stats.submit_late.text("submit_late") + video_stats.submit_gap.text("submit_gap")
                    + video_stats.pts_gap.text("pts_gap") + video_stats.host_call.text("host_call");
            }
            // Successful output clears the pending-input timer, so an idle
            // sender does not warn. A failed burst still needs a warning even
            // when its last input fell in the previous statistics interval.
            const auto output_age = now - (last_video_output ? last_video_output : video_stats_started);
            if (!video_paused && video_no_output_started
                && now - video_no_output_started >= 3 * kSecond) {
                char text[384];
                std::snprintf(text, sizeof(text),
                    "Video output stalled: decoder=%s codec=%s consumed=%llu queued=%zu last_input_age_ms=%.1f last_output_age_ms=%.1f audio_playing=%d",
                    decoder, video_hevc ? "HEVC" : "H.264",
                    static_cast<unsigned long long>(video_stats.queue_wait.count), packets.size(),
                    (now - last_video_decode) / 1e6, last_video_output ? output_age / 1e6 : -1.0, int(audio_playing));
                stall = text;
            }
            video_stats = {}; video_stats_started = now;
        }
        if (!message.empty()) log(message.c_str());
        if (!stall.empty()) log(stall.c_str(), 4 /* syslog LOG_WARNING */);
    }
};
