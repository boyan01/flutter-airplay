// SPDX-License-Identifier: GPL-3.0-only
// UxPlay integration preserves the receive core's original license notices.
#include "uxplay_adapter.h"
#include "uxplay_callbacks.h"
#include "../playback/player_internal.h"
extern "C" {
#include "dnssd.h"
#include "logger.h"
}

namespace {
AirplayPlayer *player(void *p) { return static_cast<AirplayPlayer *>(p); }
void video_process(void *cls, raop_ntp_t *, video_decode_struct *data) {
    player(cls)->receive_video(data->data, data->data_len, int64_t(data->ntp_time_local));
}
void audio_process(void *cls, raop_ntp_t *, audio_decode_struct *data) {
    player(cls)->receive_audio(data->data, data->data_len, data->ct, int64_t(data->ntp_time_local), data->rtp_time);
}
void audio_format(void *cls, unsigned char *ct, unsigned short *spf, bool *, bool *, uint64_t *) { player(cls)->format_audio(*ct, *spf); }
void video_size(void *cls, float *sw, float *sh, float *, float *) { player(cls)->resize_video(*sw, *sh); }
void reset(void *cls) { player(cls)->reset(); }
void reset_type(void *cls, reset_type_t) { reset(cls); }
void conn_reset(void *cls, int) { reset(cls); }
void audio_flush(void *cls) { player(cls)->flush_audio(); }
void video_pause(void *cls) { player(cls)->pause_video(true); }
void video_resume(void *cls) { player(cls)->pause_video(false); }
void nothing(void *) {}
void connected(void *cls) { player(cls)->protocol->connected(); }
void disconnected(void *cls) { player(cls)->protocol->disconnected(); }
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
void volume_set(void *cls, float db) { player(cls)->set_volume(db); }
int codec(void *cls, video_codec_t c) {
    if (c != VIDEO_CODEC_H264 && c != VIDEO_CODEC_H265) return -1;
    return player(cls)->select_codec(c == VIDEO_CODEC_H265);
}
void log(void *cls, int level, const char *text) { player(cls)->log(text, level); }
}  // namespace
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

namespace airplay {
struct ProtocolAdapter::Impl {
    AirplayPlayer& playback;
    raop_t* receiver = nullptr;
    dnssd_t* dns = nullptr;
    uint16_t port = 0;
    std::mutex session_lock;
    std::atomic<int> connections{0};
    explicit Impl(AirplayPlayer& value) : playback(value) {}
};
ProtocolAdapter::ProtocolAdapter(AirplayPlayer& playback) : impl_(std::make_unique<Impl>(playback)) {}
ProtocolAdapter::~ProtocolAdapter() {
    stop_receiver();
    if (impl_->dns) { dnssd_unregister_raop(impl_->dns); dnssd_unregister_airplay(impl_->dns); dnssd_destroy(impl_->dns); }
}
void ProtocolAdapter::stop_receiver() {
    if (impl_->receiver) { raop_destroy(impl_->receiver); impl_->receiver = nullptr; }
}
bool ProtocolAdapter::started() const { return impl_->receiver != nullptr; }
uint16_t ProtocolAdapter::port() const { return impl_->port; }
int ProtocolAdapter::connections() const { return impl_->connections.load(); }
void ProtocolAdapter::connected() {
    std::lock_guard<std::mutex> guard(impl_->session_lock); ++impl_->connections;
}
void ProtocolAdapter::disconnected() {
    bool ended;
    { std::lock_guard<std::mutex> guard(impl_->session_lock); ended = impl_->connections.fetch_sub(1) == 1; }
    if (ended) { impl_->playback.reset(); impl_->playback.event("waiting", "Waiting for iPhone"); }
}
bool ProtocolAdapter::prepare_restart() {
    std::lock_guard<std::mutex> guard(impl_->session_lock);
    auto& p = impl_->playback;
    if (p.closing || impl_->connections.load() != 0) return false;
    p.closing = true; p.wake.notify_all(); return true;
}
size_t ProtocolAdapter::txt(bool audio, uint8_t* output, size_t capacity) const {
    if (!impl_->dns) return 0;
    int length = 0;
    const auto* bytes = audio ? dnssd_get_raop_txt(impl_->dns, &length) : dnssd_get_airplay_txt(impl_->dns, &length);
    if (output && capacity >= size_t(length)) memcpy(output, bytes, length);
    return length;
}
bool ProtocolAdapter::start( const char *name, const uint8_t identity[6], const char *key,
                                     char *error, size_t capacity) {
    auto *p = &impl_->playback;
    auto fail = [&](const char *text) { if (error && capacity) snprintf(error, capacity, "%s", text); return false; };
    if (!p || impl_->receiver || !name || !*name || strlen(name) > 50 || !identity || !key) return fail("Invalid receiver configuration");
    auto cb = receiver_callbacks(p);
    impl_->receiver = raop_init(&cb);
    if (!impl_->receiver) return fail("Cannot initialize AirPlay receive core");
    raop_set_log_callback(impl_->receiver, log, p); raop_set_log_level(impl_->receiver, LOGGER_INFO);
    char id[18]; snprintf(id, sizeof(id), "%02X:%02X:%02X:%02X:%02X:%02X", identity[0], identity[1], identity[2], identity[3], identity[4], identity[5]);
    if (raop_init2(impl_->receiver, 1, id, key)) return fail("Cannot initialize private pairing key");
    int dns_error = 0;
    impl_->dns = dnssd_init(name, int(strlen(name)), reinterpret_cast<const char *>(identity), 6, &dns_error, 0);
    if (!impl_->dns) return fail("Cannot initialize discovery records");
    raop_set_dnssd(impl_->receiver, impl_->dns);
    dnssd_set_airplay_features(impl_->dns, 0, 0); dnssd_set_airplay_features(impl_->dns, 4, 0);
    dnssd_set_airplay_features(impl_->dns, 7, 1);
    dnssd_set_airplay_features(impl_->dns, 27, p->fast_pairing ? 0 : 1);
    dnssd_set_airplay_features(impl_->dns, 42, p->video->supports_hevc() ? 1 : 0);
    raop_set_plist(impl_->receiver, "width", p->requested_width); raop_set_plist(impl_->receiver, "height", p->requested_height); raop_set_plist(impl_->receiver, "maxFPS", 60);
    if (raop_start_httpd(impl_->receiver, &impl_->port) < 0 || !impl_->port) return fail("Cannot bind AirPlay listener");
    raop_set_port(impl_->receiver, impl_->port);
    if (dnssd_register_raop(impl_->dns, impl_->port) || dnssd_register_airplay(impl_->dns, impl_->port)) return fail("Cannot register discovery services");
    p->log(p->fast_pairing ? "Fast pairing: enabled; legacy pairing advertisement disabled"
                           : "Fast pairing: disabled; legacy pairing advertisement enabled");
#if defined(__APPLE__) && TARGET_OS_OSX
    p->log("macOS playback buffer: 120 ms; shared audio/video timeline");
#endif
    p->log(p->video->supports_hevc()
        ? "Shared C++ player: H.264 / HEVC / AAC / ALAC, 60 FPS capability, common monotonic timeline"
        : "Shared C++ player: H.264 / AAC / ALAC, 60 FPS capability, common monotonic timeline");
    return true;
}

}  // namespace airplay
