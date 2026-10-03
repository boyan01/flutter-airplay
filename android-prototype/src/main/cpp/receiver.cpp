// SPDX-License-Identifier: GPL-3.0-or-later
#include "receiver.h"
#include <cstdio>
#include <cstring>
#include <utility>
namespace airplay {
static void video(void *cls, raop_ntp_t *, video_decode_struct *d) {
    if (d->data_len <= 0 || d->data_len > 2 * 1024 * 1024) return;
    Packet p; p.kind = 1; p.codec = d->is_h265 ? 2 : 1; p.pts = d->ntp_time_local;
    p.bytes.assign(d->data, d->data + d->data_len);
    static_cast<Receiver *>(cls)->enqueue(std::move(p));
}
static void audio(void *cls, raop_ntp_t *, audio_decode_struct *d) {
    if (d->data_len <= 0 || d->data_len > 65536) return;
    Packet p; p.kind = 2; p.codec = d->ct; p.pts = d->ntp_time_local;
    p.rtp = d->rtp_time; p.sync = d->sync_status;
    p.bytes.assign(d->data, d->data + d->data_len);
    static_cast<Receiver *>(cls)->enqueue(std::move(p));
}
static void flushCallback(void *cls) { static_cast<Receiver *>(cls)->flush(); }
static void reset(void *cls, reset_type_t) { flushCallback(cls); }
static void connReset(void *cls, int) { flushCallback(cls); }
static void nothing(void *) {}
static double volume(void *) { return 0.0; }
static int codec(void *, video_codec_t value) {
    return value == VIDEO_CODEC_H264 || value == VIDEO_CODEC_H265 ? 0 : -1;
}
static void logDiscard(void *, int, const char *) {}
Receiver::~Receiver() { stop(); }
int Receiver::start(const char *name, const uint8_t identity[6], const char *keyfile) {
    if (raop_ || !name || !*name || strlen(name) > 48 || !identity || !keyfile) return -1;
    raop_callbacks_t cb{}; cb.cls = this;
    cb.audio_process = audio; cb.video_process = video;
    cb.video_pause = nothing; cb.video_resume = nothing; cb.conn_feedback = nothing;
    cb.conn_reset = connReset; cb.video_reset = reset;
    cb.conn_destroy = flushCallback; cb.audio_flush = flushCallback; cb.video_flush = flushCallback;
    cb.audio_set_client_volume = volume; cb.video_set_codec = codec;
    raop_ = raop_init(&cb);
    if (!raop_) return -1;
    // UxPlay requires a log callback. Default to silence: the host may later
    // expose bounded, redacted diagnostics without leaking sender metadata.
    raop_set_log_callback(raop_, logDiscard, nullptr);
    raop_set_log_level(raop_, 3);
    char id[18];
    snprintf(id, sizeof(id), "%02X:%02X:%02X:%02X:%02X:%02X", identity[0], identity[1],
        identity[2], identity[3], identity[4], identity[5]);
    if (raop_init2(raop_, 1, id, keyfile)) { stop(); return -1; }
    int err = 0;
    dns_ = dnssd_init(name, (int)strlen(name), (const char *)identity, 6, &err, 0);
    if (!dns_) { stop(); return -1; }
    raop_set_dnssd(raop_, dns_);
    // HLS remains disabled; playback integration must narrow other feature bits.
    dnssd_set_airplay_features(dns_, 0, 0);
    dnssd_set_airplay_features(dns_, 4, 0);
    dnssd_set_airplay_features(dns_, 7, 1);
    raop_set_plist(raop_, "width", 1920); raop_set_plist(raop_, "height", 1080);
    raop_set_plist(raop_, "maxFPS", 60);
    unsigned short port = 0;
    if (raop_start_httpd(raop_, &port) < 0 || !port) { stop(); return -1; }
    raop_set_port(raop_, port);
    if (dnssd_register_raop(dns_, port) || dnssd_register_airplay(dns_, port)) {
        stop(); return -1;
    }
    return port;
}
void Receiver::stop() {
    // UxPlay joins all owned network callbacks before freeing their cls.
    if (raop_) { raop_destroy(raop_); raop_ = nullptr; }
    if (dns_) {
        dnssd_unregister_raop(dns_); dnssd_unregister_airplay(dns_);
        dnssd_destroy(dns_); dns_ = nullptr;
    }
    flush();
}
std::vector<uint8_t> Receiver::txt(bool audio) const {
    if (!dns_) return {};
    int n = 0;
    const char *bytes = audio ? dnssd_get_raop_txt(dns_, &n) : dnssd_get_airplay_txt(dns_, &n);
    if (!bytes || n <= 0) return {};
    return std::vector<uint8_t>(bytes, bytes + n);
}
void Receiver::enqueue(Packet p) {
    std::lock_guard<std::mutex> guard(mutex_);
    if (p.bytes.empty() || p.bytes.size() > 2 * 1024 * 1024) { ++dropped_; return; }
    // Overflow invalidates the whole decode epoch: compressed video may depend
    // on earlier frames. Consumers must flush and wait for codec config/IDR.
    if (queue_.size() >= 128 || queuedBytes_ + p.bytes.size() > 8 * 1024 * 1024) {
        dropped_ += queue_.size(); queue_.clear(); queuedBytes_ = 0; ++epoch_;
    }
    p.epoch = epoch_; queuedBytes_ += p.bytes.size(); queue_.push_back(std::move(p));
}
bool Receiver::poll(Packet &p) {
    std::lock_guard<std::mutex> guard(mutex_);
    if (queue_.empty()) return false;
    p = std::move(queue_.front()); queue_.pop_front(); queuedBytes_ -= p.bytes.size();
    return true;
}
void Receiver::flush() {
    std::lock_guard<std::mutex> guard(mutex_);
    queue_.clear(); queuedBytes_ = 0; ++epoch_;
}
uint64_t Receiver::dropped() { std::lock_guard<std::mutex> guard(mutex_); return dropped_; }
uint64_t Receiver::epoch() { std::lock_guard<std::mutex> guard(mutex_); return epoch_; }
}
