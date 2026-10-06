// SPDX-License-Identifier: GPL-3.0-or-later
#include "../../native/include/airplay/receiver.h"
#include <cstdio>
#include <cstring>
namespace airplay {
static void video(void *, raop_ntp_t *, video_decode_struct *) {}
static void audio(void *, raop_ntp_t *, audio_decode_struct *) {}
static void reset(void *, reset_type_t) {}
static void connReset(void *, int) {}
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
    cb.conn_destroy = nothing; cb.audio_flush = nothing; cb.video_flush = nothing;
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
}
std::vector<uint8_t> Receiver::txt(bool audio) const {
    if (!dns_) return {};
    int n = 0;
    const char *bytes = audio ? dnssd_get_raop_txt(dns_, &n) : dnssd_get_airplay_txt(dns_, &n);
    if (!bytes || n <= 0) return {};
    return std::vector<uint8_t>(bytes, bytes + n);
}
}
