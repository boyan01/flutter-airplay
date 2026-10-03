// SPDX-License-Identifier: GPL-3.0-only
// ALAC cookie and AAC configuration derived from jqssun/android-airplay-server;
// see THIRD_PARTY_NOTICES.md and android/NOTICE.
#pragma once
#include "timeline.h"
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
}

namespace airplay {
class AudioDecoder {
public:
    AudioDecoder(std::shared_ptr<AudioBuffer> buffer, std::function<void(const char *)> log)
        : buffer_(std::move(buffer)), log_(std::move(log)) {}
    ~AudioDecoder() { clear(); }
    void format(int ct, int spf) {
        std::lock_guard<std::mutex> guard(lock_);
        if (ct_ != ct || spf_ != spf) { clear(); ct_ = ct; spf_ = spf; }
    }
    void flush() {
        std::lock_guard<std::mutex> guard(lock_);
        if (codec_) avcodec_flush_buffers(codec_);
        buffer_->flush();
    }
    bool decode(const uint8_t *data, size_t size, int ct, int64_t deadline, bool *produced = nullptr) {
        if (produced) *produced = false;
        std::lock_guard<std::mutex> guard(lock_);
        if (ct != ct_) { clear(); ct_ = ct; spf_ = ct == 2 ? 352 : ct == 4 ? 1024 : 480; }
        if (!codec_ && !open()) return false;
        const auto generation = buffer_->generation();
        av_packet_unref(packet_);
        if (av_new_packet(packet_, int(size)) < 0) return false;
        memcpy(packet_->data, data, size);
        if (avcodec_send_packet(codec_, packet_) < 0) return false;
        while (avcodec_receive_frame(codec_, frame_) == 0) {
            if (frame_->sample_rate != kSampleRate || frame_->ch_layout.nb_channels != 2) {
                log_("Unsupported decoded audio rate/channel count"); av_frame_unref(frame_); return false;
            }
            std::vector<int16_t> pcm(size_t(frame_->nb_samples) * 2);
            const auto format = AVSampleFormat(frame_->format);
            const bool planar = av_sample_fmt_is_planar(format);
            const auto packed = av_get_packed_sample_fmt(format);
            for (int i = 0; i < frame_->nb_samples; ++i) for (int channel = 0; channel < 2; ++channel) {
                const uint8_t *base = frame_->extended_data[planar ? channel : 0];
                const size_t index = planar ? i : i * 2 + channel;
                float value;
                switch (packed) {
                case AV_SAMPLE_FMT_S16: value = reinterpret_cast<const int16_t *>(base)[index]; break;
                case AV_SAMPLE_FMT_S32: value = reinterpret_cast<const int32_t *>(base)[index] / 65536.f; break;
                case AV_SAMPLE_FMT_FLT: value = reinterpret_cast<const float *>(base)[index] * 32768.f; break;
                default: log_("Unsupported decoded audio sample format"); av_frame_unref(frame_); return false;
                }
                pcm[size_t(i) * 2 + channel] = int16_t(std::clamp(value, -32768.f, 32767.f));
            }
            const auto written = buffer_->write(pcm.data(), frame_->nb_samples, deadline, generation);
            if (produced && written > 0) *produced = true;
            if (written != size_t(frame_->nb_samples))
                log_("Audio queue full; dropping stale backlog input");
            deadline += int64_t(frame_->nb_samples) * kSecond / kSampleRate;
            av_frame_unref(frame_);
        }
        return true;
    }
private:
    void clear() { avcodec_free_context(&codec_); av_packet_free(&packet_); av_frame_free(&frame_); }
    bool open() {
        const auto id = ct_ == 2 ? AV_CODEC_ID_ALAC : AV_CODEC_ID_AAC;
        const AVCodec *decoder = avcodec_find_decoder(id);
        if (!decoder || (ct_ != 2 && ct_ != 4 && ct_ != 8)) return false;
        codec_ = avcodec_alloc_context3(decoder);
        if (!codec_) return false;
        codec_->sample_rate = kSampleRate;
        av_channel_layout_default(&codec_->ch_layout, 2);
        codec_->thread_count = 1;
        codec_->extradata_size = ct_ == 2 ? 36 : ct_ == 8 ? 4 : 2;
        codec_->extradata = static_cast<uint8_t *>(av_mallocz(codec_->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE));
        if (!codec_->extradata) { clear(); return false; }
        auto *cookie = codec_->extradata;
        if (ct_ == 2) {
            cookie[3] = 36; memcpy(cookie + 4, "alac", 4);
            const int spf = spf_ > 0 ? spf_ : 352;
            cookie[12] = spf >> 24; cookie[13] = spf >> 16; cookie[14] = spf >> 8; cookie[15] = spf;
            cookie[17] = 16; cookie[18] = 40; cookie[19] = 10; cookie[20] = 14; cookie[21] = 2;
            cookie[22] = 0; cookie[23] = 255;
            cookie[32] = kSampleRate >> 24; cookie[33] = kSampleRate >> 16;
            cookie[34] = kSampleRate >> 8; cookie[35] = uint8_t(kSampleRate);
        } else if (ct_ == 8) {
            cookie[0] = 0xf8; cookie[1] = 0xe8; cookie[2] = spf_ == 512 ? 0x40 : 0x50;
        } else { cookie[0] = 0x12; cookie[1] = spf_ == 960 ? 0x14 : 0x10; }
        if (avcodec_open2(codec_, decoder, nullptr) < 0) { log_("Cannot open shared audio decoder"); clear(); return false; }
        packet_ = av_packet_alloc(); frame_ = av_frame_alloc();
        if (!packet_ || !frame_) { clear(); return false; }
        log_(ct_ == 2 ? "Shared FFmpeg ALAC decoder ready" : "Shared FFmpeg AAC decoder ready");
        return true;
    }
    std::mutex lock_;
    std::shared_ptr<AudioBuffer> buffer_;
    std::function<void(const char *)> log_;
    AVCodecContext *codec_ = nullptr;
    AVPacket *packet_ = nullptr;
    AVFrame *frame_ = nullptr;
    int ct_ = 8, spf_ = 480;
};
} // namespace airplay
