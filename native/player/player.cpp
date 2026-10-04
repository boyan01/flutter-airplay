// SPDX-License-Identifier: GPL-3.0-only
// Receiver callbacks derived from this project's Android JNI host; UxPlay
// remains the shared C receive core, with its original license notices.
#include "platform.h"
#include "audio_decoder.h"
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <thread>
#include <string>
extern "C" {
#include "raop.h"
#include "dnssd.h"
#include "logger.h"
}
using namespace airplay;

struct AirplayPlayer {
    AirplayCallbacks callbacks;
    std::atomic<bool> closing{false};
    std::atomic<int> connections{0};
    raop_t *receiver = nullptr;
    dnssd_t *dns = nullptr;
    uint16_t port = 0;
    Timeline timeline;
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
    bool audio_playing = false;
    int width = 1920, height = 1080;
    int requested_width = 1920, requested_height = 1080;
    size_t queued_bytes = 0;

    AirplayPlayer(AirplayCallbacks cb, void *surface, const char *decoder, const char *fallback)
        : callbacks(cb), audio(pcm, [this](const char *text) { log(text); }) {
        output = make_audio_output(pcm);
        video = make_video_output(surface, decoder, fallback, {
            [this](void *frame, int w, int h, int64_t due, uint64_t generation) {
                // macOS decoding is synchronous on worker; keep waits cancellable.
                std::unique_lock<std::mutex> guard(lock);
                if (closing || video_paused || generation != video_generation) return;
                const auto delay = due - monotonic_ns();
                if (delay > 0 && frame) wake.wait_for(guard, std::chrono::nanoseconds(delay), [&] {
                    return closing || video_paused || generation != video_generation;
                });
                if (closing || video_paused || generation != video_generation || due < monotonic_ns() - 150000000) return;
                if (frame && callbacks.frame) callbacks.frame(callbacks.context, frame);
                event("playing", "Decoded video ready", w, h);
            }, [this](const char *text) { log(text); }
        });
        worker = std::thread([this] { run(); });
    }
    ~AirplayPlayer() {
        closing = true; wake.notify_all();
        if (receiver) raop_destroy(receiver); // joins all network callbacks first
        if (worker.joinable()) worker.join();
        video.reset();
        output->stop(); output.reset();
        if (dns) { dnssd_unregister_raop(dns); dnssd_unregister_airplay(dns); dnssd_destroy(dns); }
    }
    void log(const char *text, int level = LOGGER_INFO) {
        if (!closing && callbacks.log) callbacks.log(callbacks.context, level, text);
    }
    void event(const char *type, const char *detail, int w = 0, int h = 0) {
        if (!closing && callbacks.event) callbacks.event(callbacks.context, type, detail, w, h);
    }
    void reset() {
        { std::lock_guard<std::mutex> guard(lock);
          ++video_generation; packets.clear(); queued_bytes = 0; video_reset = true;
          video_paused = false;
          audio_playing = false;
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
        while (!closing) {
            VideoPacket packet;
            int w, h;
            bool reset;
            { std::unique_lock<std::mutex> guard(lock);
              wake.wait_for(guard, std::chrono::milliseconds(5), [&] { return closing || video_reset || !packets.empty(); });
              if (closing) break;
              reset = video_reset; video_reset = false; generation = video_generation; w = width; h = height;
              if (!packets.empty()) { packet = std::move(packets.front()); packets.pop_front(); queued_bytes -= packet.bytes.size(); } }
            if (reset) video->reset();
            video->size(w, h);
            if (!packet.bytes.empty() && packet.generation == generation && !video->decode(packet)) {
                video->reset(); event("error", "Video decoding failed; reconnect screen mirroring");
            }
            video->drain();
        }
        video->reset();
    }
};

namespace {
AirplayPlayer *player(void *p) { return static_cast<AirplayPlayer *>(p); }
void video_process(void *cls, raop_ntp_t *, video_decode_struct *data) {
    auto *p = player(cls);
    if (p->closing || data->data_len < 5 || data->data_len > 4 * 1024 * 1024) return;
    const auto now = monotonic_ns();
    const auto due = p->timeline.deadline(data->ntp_time_local ? int64_t(data->ntp_time_local) : realtime_ns(), now);
    if (due < now - kSecond || due > now + 2 * kSecond) { p->log("Rejected out-of-window video timestamp"); return; }
    std::lock_guard<std::mutex> guard(p->lock);
    // Keep compressed dependencies intact: backpressure overflow forces a keyframe restart.
    if (p->queued_bytes + data->data_len > 16 * 1024 * 1024) {
        p->packets.clear(); p->queued_bytes = 0; p->video_reset = true;
        ++p->video_generation; p->log("Video input backlog reset; waiting for a keyframe");
    }
    p->packets.push_back({std::vector<uint8_t>(data->data, data->data + data->data_len), due, p->video_generation});
    p->queued_bytes += data->data_len; p->wake.notify_all();
}
void audio_process(void *cls, raop_ntp_t *, audio_decode_struct *data) {
    auto *p = player(cls);
    if (p->closing || data->data_len <= 0 || data->data_len > 65536) return;
    const auto now = monotonic_ns();
    const auto due = p->timeline.deadline(data->ntp_time_local ? int64_t(data->ntp_time_local) : realtime_ns(), now);
    if (due < now - kSecond || due > now + 2 * kSecond) { p->log("Rejected out-of-window audio timestamp"); return; }
    const auto generation = p->pcm->generation();
    bool produced = false;
    if (!p->audio.decode(data->data, data->data_len, data->ct, due, &produced)) {
        p->log("Audio packet could not be decoded");
    } else if (produced) {
        std::lock_guard<std::mutex> guard(p->lock);
        if (generation == p->pcm->generation() && !p->audio_playing) {
            p->audio_playing = true;
            p->event("audio", "Decoded audio ready");
        }
    }
}
void audio_format(void *cls, unsigned char *ct, unsigned short *spf, bool *, bool *, uint64_t *) {
    auto *p = player(cls); p->audio.format(*ct, *spf);
    if (!p->output->start()) p->event("error", "Cannot open audio output");
}
void video_size(void *cls, float *sw, float *sh, float *, float *) {
    auto *p = player(cls);
    if (*sw < 1 || *sh < 1 || *sw > 4096 || *sh > 4096) return;
    { std::lock_guard<std::mutex> guard(p->lock); p->width = int(*sw); p->height = int(*sh); }
    p->event("size", "Video dimensions", int(*sw), int(*sh));
}
void reset(void *cls) { player(cls)->reset(); }
void reset_type(void *cls, reset_type_t) { reset(cls); }
void conn_reset(void *cls, int) { reset(cls); }
void audio_flush(void *cls) {
    auto *p = player(cls);
    std::lock_guard<std::mutex> guard(p->lock);
    p->audio.flush();
    if (p->audio_playing) { p->audio_playing = false; p->event("audio_stopped", "Audio paused"); }
}
void video_pause(void *cls) { player(cls)->pause_video(true); }
void video_resume(void *cls) { player(cls)->pause_video(false); }
void nothing(void *) {}
void connected(void *cls) { player(cls)->connections.fetch_add(1); }
void disconnected(void *cls) {
    auto *p = player(cls);
    if (p->connections.fetch_sub(1) == 1) { p->reset(); p->event("waiting", "Waiting for iPhone"); }
}
void client(void *cls, char *, char *, char *name, bool *admit) {
    *admit = true;
    std::string clean;
    for (size_t i = 0; name && name[i] && i < 512; ++i) {
        const auto c = uint8_t(name[i]); if (c >= 32 && c != 127) clean += name[i];
    }
    player(cls)->event("client", clean.c_str());
}
void mirror(void *cls, bool running) { if (running) player(cls)->event("connecting", "Sender connected"); }
double volume(void *) { return 0.; }
void volume_set(void *cls, float db) { player(cls)->pcm->volume(db); }
int codec(void *, video_codec_t c) { return c == VIDEO_CODEC_H264 ? 0 : -1; }
void log(void *cls, int level, const char *text) { player(cls)->log(text, level); }
raop_callbacks_t receiver_callbacks(AirplayPlayer *p) {
    raop_callbacks_t cb{}; cb.cls = p;
    cb.audio_process = audio_process; cb.video_process = video_process; cb.audio_get_format = audio_format;
    cb.video_report_size = video_size; cb.audio_flush = audio_flush; cb.video_flush = reset;
    cb.video_pause = video_pause; cb.video_resume = video_resume; cb.conn_feedback = nothing; cb.conn_reset = conn_reset;
    cb.video_reset = reset_type; cb.conn_init = connected; cb.conn_destroy = disconnected;
    cb.report_client_request = client; cb.mirror_video_running = mirror;
    cb.audio_set_client_volume = volume; cb.audio_set_volume = volume_set; cb.video_set_codec = codec;
    return cb;
}
}

extern "C" AirplayPlayer *airplay_player_create(AirplayCallbacks cb, void *surface, const char *decoder, const char *fallback) {
    try { return new AirplayPlayer(cb, surface, decoder, fallback); } catch (...) { return nullptr; }
}
extern "C" bool airplay_player_set_video_size(AirplayPlayer *p, int width, int height) {
    if (!p || p->receiver || width < 1 || height < 1 || width > 4096 || height > 4096) return false;
    p->requested_width = width; p->requested_height = height;
    return true;
}
extern "C" bool airplay_player_start(AirplayPlayer *p, const char *name, const uint8_t identity[6], const char *key,
                                     char *error, size_t capacity) {
    auto fail = [&](const char *text) { if (error && capacity) snprintf(error, capacity, "%s", text); return false; };
    if (!p || p->receiver || !name || !*name || strlen(name) > 50 || !identity || !key) return fail("Invalid receiver configuration");
    auto cb = receiver_callbacks(p);
    p->receiver = raop_init(&cb);
    if (!p->receiver) return fail("Cannot initialize AirPlay receive core");
    raop_set_log_callback(p->receiver, log, p); raop_set_log_level(p->receiver, LOGGER_INFO);
    char id[18]; snprintf(id, sizeof(id), "%02X:%02X:%02X:%02X:%02X:%02X", identity[0], identity[1], identity[2], identity[3], identity[4], identity[5]);
    if (raop_init2(p->receiver, 1, id, key)) return fail("Cannot initialize private pairing key");
    int dns_error = 0;
    p->dns = dnssd_init(name, int(strlen(name)), reinterpret_cast<const char *>(identity), 6, &dns_error, 0);
    if (!p->dns) return fail("Cannot initialize discovery records");
    raop_set_dnssd(p->receiver, p->dns);
    dnssd_set_airplay_features(p->dns, 0, 0); dnssd_set_airplay_features(p->dns, 4, 0);
    dnssd_set_airplay_features(p->dns, 7, 1); dnssd_set_airplay_features(p->dns, 42, 0);
    raop_set_plist(p->receiver, "width", p->requested_width); raop_set_plist(p->receiver, "height", p->requested_height); raop_set_plist(p->receiver, "maxFPS", 60);
    if (raop_start_httpd(p->receiver, &p->port) < 0 || !p->port) return fail("Cannot bind AirPlay listener");
    raop_set_port(p->receiver, p->port);
    if (dnssd_register_raop(p->dns, p->port) || dnssd_register_airplay(p->dns, p->port)) return fail("Cannot register discovery services");
    p->log("Shared C++ player: H.264 / AAC / ALAC, 60 FPS capability, common monotonic timeline");
    return true;
}
extern "C" uint16_t airplay_player_port(AirplayPlayer *p) { return p ? p->port : 0; }
extern "C" size_t airplay_player_txt(AirplayPlayer *p, bool audio, uint8_t *output, size_t capacity) {
    if (!p || !p->dns) return 0;
    int length = 0;
    const auto *bytes = audio ? dnssd_get_raop_txt(p->dns, &length) : dnssd_get_airplay_txt(p->dns, &length);
    if (output && capacity >= size_t(length)) memcpy(output, bytes, length);
    return length;
}
extern "C" void airplay_player_destroy(AirplayPlayer *p) { delete p; }
