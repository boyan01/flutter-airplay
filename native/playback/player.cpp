// SPDX-License-Identifier: GPL-3.0-only
#include "player_internal.h"

void AirplayPlayer::receive_video(const uint8_t* bytes, int size, int64_t local_pts) {
    auto *p = this;
    if (p->closing || size < 5 || size > 4 * 1024 * 1024) return;
    const auto now = monotonic_ns();
    const auto due = p->timeline.deadline(local_pts ? int64_t(local_pts) : realtime_ns(), now);
    if (due < now - kSecond || due > now + 2 * kSecond) { p->log("Rejected out-of-window video timestamp"); return; }
    std::lock_guard<std::mutex> guard(p->lock);
    // Keep compressed dependencies intact: backpressure overflow forces a keyframe restart.
    if (p->queued_bytes + size > 16 * 1024 * 1024) {
        p->packets.clear(); p->queued_bytes = 0; p->video_reset = true;
        ++p->video_generation; p->log("Video input backlog reset; waiting for a keyframe");
    }
    p->packets.push_back({std::vector<uint8_t>(bytes, bytes + size), due, p->video_generation, now, p->video_hevc});
    p->queued_bytes += size;
    if (!p->video_report_ns) p->video_report_ns = now;
    if (p->video_arrival_ns) p->video_gap_ns = std::max(p->video_gap_ns, now - p->video_arrival_ns);
    p->video_arrival_ns = now;
    ++p->video_received;
    p->video_peak_queue = std::max(p->video_peak_queue, p->packets.size());
    if (now - p->video_report_ns >= 5 * kSecond) {
        char message[256];
        std::snprintf(message, sizeof(message),
            "Video receive stats: interval_ms=%lld packets=%llu max_arrival_gap_ms=%.1f queued=%zu peak_queued=%zu queued_bytes=%zu",
            static_cast<long long>((now - p->video_report_ns) / 1000000),
            static_cast<unsigned long long>(p->video_received), p->video_gap_ns / 1000000.0,
            p->packets.size(), p->video_peak_queue, p->queued_bytes);
        p->log(message);
        p->video_report_ns = now; p->video_received = 0; p->video_gap_ns = 0;
        p->video_peak_queue = p->packets.size();
    }
    p->wake.notify_all();
}
void AirplayPlayer::receive_audio(const uint8_t* bytes, int size, int ct, int64_t local_pts, uint32_t rtp) {
    auto *p = this;
    if (p->closing || size <= 0 || size > 65536) return;
    ++p->audio_packets; p->audio_bytes.fetch_add(size);
    const auto now = monotonic_ns();
    const auto due = p->timeline.deadline(p->audio_pts(int64_t(local_pts), rtp), now);
    p->audio_lead_ms.store((due - now) / 1000000);
    if (due < now - kSecond || due > now + 2 * kSecond) { ++p->audio_timestamp_rejects; return; }
    const auto generation = p->pcm->generation();
    bool produced = false;
    if (!p->audio.decode(bytes, size, ct, due, &produced)) {
        if (p->audio_decode_errors.fetch_add(1) == 0) p->log("Audio packet could not be decoded; see audio receive totals");
    } else if (produced) {
        ++p->audio_pcm_packets;
        std::lock_guard<std::mutex> guard(p->lock);
        if (generation == p->pcm->generation() && !p->audio_playing) {
            p->audio_playing = true;
            p->event("audio", "Decoded audio ready");
        }
    }
}
extern "C" AirplayPlayer *airplay_player_create(AirplayCallbacks cb, void *surface, const char *decoder, const char *fallback) {
    try { return new AirplayPlayer(cb, surface, decoder, fallback); } catch (...) { return nullptr; }
}
extern "C" bool airplay_player_set_video_size(AirplayPlayer *p, int width, int height) {
    if (!p || p->protocol->started() || width < 1 || height < 1 || width > 4096 || height > 4096) return false;
    p->requested_width = width; p->requested_height = height;
    return true;
}
extern "C" bool airplay_player_set_fast_pairing(AirplayPlayer *p, bool enabled) {
    if (!p || p->protocol->started()) return false;
    p->fast_pairing = enabled;
    return true;
}
extern "C" bool airplay_player_start(AirplayPlayer *p, const char *name, const uint8_t identity[6], const char *key,
                                     char *error, size_t capacity) {
    return p && p->protocol->start(name, identity, key, error, capacity);
}
extern "C" uint16_t airplay_player_port(AirplayPlayer *p) { return p ? p->protocol->port() : 0; }
extern "C" size_t airplay_player_txt(AirplayPlayer *p, bool audio, uint8_t *output, size_t capacity) {
    return p ? p->protocol->txt(audio, output, capacity) : 0;
}
extern "C" void airplay_player_destroy(AirplayPlayer *p) { delete p; }
extern "C" bool airplay_player_prepare_restart(AirplayPlayer *p) {
    if (!p) return false;
    return p->protocol->prepare_restart();
}

#ifdef __ANDROID__
extern "C" bool airplay_player_set_hevc_decoder(AirplayPlayer *p, const char *decoder) {
    return p && !p->protocol->started() && decoder && p->video->set_hevc_decoder(decoder);
}
extern "C" bool airplay_player_set_surface(AirplayPlayer *p, void *surface) {
    return p && surface && p->video->set_surface(surface);
}
extern "C" bool airplay_player_set_audio_output(AirplayPlayer *p, int mode) {
    if (!p || p->protocol->started() || mode < 0 || mode > 2) return false;
    p->output = make_android_audio_output(p->pcm, mode, [p](const char *text) { p->log(text); });
    return true;
}
#endif

void AirplayPlayer::format_audio(uint8_t ct, uint16_t spf) {
    auto *p = this; p->audio.format(ct, spf);
    { std::lock_guard<std::mutex> guard(p->lock); p->audio_rtp_anchored = false; }
    char message[160];
    std::snprintf(message, sizeof(message), "Audio format: codec=%s ct=%u samples_per_packet=%u rate=%d channels=2",
        ct == 2 ? "ALAC" : ct == 4 ? "AAC" : ct == 8 ? "AAC-ELD" : "unknown", ct, spf, kSampleRate);
    p->log(message);
    const auto started = p->output->start();
    p->log(started ? "Audio output start requested" : "Audio output start failed");
    const auto report = p->output->diagnostics();
    if (!report.empty()) p->log(report.c_str());
    if (!started) p->log("Audio output error: cannot open output; video continues");
}
void AirplayPlayer::resize_video(float width, float height) {
    auto *p = this;
    if (width < 1 || height < 1 || width > 4096 || height > 4096) return;
    { std::lock_guard<std::mutex> guard(p->lock); p->width = int(width); p->height = int(height); }
    p->event("size", "Video dimensions", int(width), int(height));
}
void AirplayPlayer::flush_audio() {
    auto *p = this;
    std::lock_guard<std::mutex> guard(p->lock);
    p->audio_rtp_anchored = false;
    p->audio.flush();
    if (p->audio_playing) { p->audio_playing = false; p->event("audio_stopped", "Audio paused"); }
}
void AirplayPlayer::set_volume(float db) {
    auto *p = this; p->pcm->volume(db);
    char message[96];
    std::snprintf(message, sizeof(message), "Sender audio volume: db=%.1f muted=%s", db, db <= -144 ? "true" : "false");
    p->log(message);
}
int AirplayPlayer::select_codec(bool hevc) {
    auto *p = this;
    if (hevc && !p->video->supports_hevc()) return -1;
    {
        std::lock_guard<std::mutex> guard(p->lock);
        if (p->video_hevc != hevc) {
            p->video_hevc = hevc;
            ++p->video_generation; p->packets.clear(); p->queued_bytes = 0; p->video_reset = true;
        }
    }
    p->log(hevc ? "Video codec selected: HEVC (H.265)" : "Video codec selected: H.264");
    p->wake.notify_all();
    return 0;
}
