// SPDX-License-Identifier: GPL-3.0-only
// AAC configuration derived from jqssun/android-airplay-server;
// see THIRD_PARTY_NOTICES.md and android/NOTICE.
#include "audio_decoder.h"
#include "alac_decoder.h"
#include <media/NdkMediaCodec.h>
#include <cstring>
#include <cstdio>

namespace airplay {
struct AudioDecoder::Codec {
    std::unique_ptr<AlacDecoder> alac;
    AMediaCodec *aac = nullptr;
    bool pcm_logged = false;
    ~Codec() { if (aac) { AMediaCodec_stop(aac); AMediaCodec_delete(aac); } }
};
AudioDecoder::AudioDecoder(std::shared_ptr<AudioBuffer> buffer, std::function<void(const char *)> log)
    : buffer_(std::move(buffer)), log_(std::move(log)) {}
AudioDecoder::~AudioDecoder() = default;
void AudioDecoder::clear() { codec_.reset(); }

bool AudioDecoder::open() {
    auto failed = [&](const char *stage, int status) {
        if (!open_error_logged_) {
            char message[160];
            std::snprintf(message, sizeof(message), "Android audio decoder open failed: stage=%s status=%d ct=%d samples_per_packet=%d", stage, status, ct_, spf_);
            log_(message); open_error_logged_ = true;
        }
        return false;
    };
    auto candidate = std::make_unique<Codec>();
    if (ct_ == 2) {
        candidate->alac = std::make_unique<AlacDecoder>();
        if (!candidate->alac->open(spf_)) return failed("ALAC configuration", -1);
    } else {
        if ((ct_ == 4 && spf_ != 960 && spf_ != 1024) || (ct_ == 8 && spf_ != 480 && spf_ != 512)) return failed("samples per packet", -1);
        candidate->aac = AMediaCodec_createDecoderByType("audio/mp4a-latm");
        if (!candidate->aac) return failed("create AAC decoder", -1);
        auto *format = AMediaFormat_new();
        AMediaFormat_setString(format, "mime", "audio/mp4a-latm");
        AMediaFormat_setInt32(format, "sample-rate", kSampleRate);
        AMediaFormat_setInt32(format, "channel-count", 2);
        AMediaFormat_setInt32(format, "aac-profile", ct_ == 8 ? 39 : 2);
        AMediaFormat_setInt32(format, "pcm-encoding", 2);
        const uint8_t aac[] = {0x12, uint8_t(spf_ == 960 ? 0x14 : 0x10)};
        const uint8_t eld[] = {0xf8, 0xe8, uint8_t(spf_ == 512 ? 0x40 : 0x50), 0};
        AMediaFormat_setBuffer(format, "csd-0", ct_ == 8 ? eld : aac, ct_ == 8 ? sizeof(eld) : sizeof(aac));
        const auto status = AMediaCodec_configure(candidate->aac, format, nullptr, nullptr, 0);
        AMediaFormat_delete(format);
        if (status != AMEDIA_OK) return failed("configure AAC decoder", status);
        const auto started = AMediaCodec_start(candidate->aac);
        if (started != AMEDIA_OK) return failed("start AAC decoder", started);
    }
    open_error_logged_ = false;
    codec_ = std::move(candidate);
    log_(ct_ == 2 ? "Apple ALAC decoder ready" : ct_ == 8 ? "MediaCodec AAC-ELD decoder ready" : "MediaCodec AAC decoder ready");
    return true;
}

bool AudioDecoder::decode_packet(const uint8_t *data, size_t size, int64_t deadline, uint64_t generation, bool *produced) {
    auto report_pcm = [&](const std::vector<int16_t> &pcm) {
        if (codec_->pcm_logged || pcm.empty()) return;
        codec_->pcm_logged = true;
        int peak = 0;
        for (const auto sample : pcm) peak = std::max(peak, std::abs(int(sample)));
        char message[160];
        std::snprintf(message, sizeof(message), "Android audio first PCM: ct=%d frames=%zu peak_before_volume=%d lead_ms=%lld",
            ct_, pcm.size() / 2, peak, static_cast<long long>((deadline - monotonic_ns()) / 1000000));
        log_(message);
    };
    if (codec_->alac) {
        std::vector<int16_t> pcm;
        if (!codec_->alac->decode(data, size, pcm)) return false;
        report_pcm(pcm);
        write_pcm(pcm.data(), pcm.size() / 2, deadline, generation, produced);
        return true;
    }
    auto drain = [&](int64_t timeout) {
        for (;;) {
            AMediaCodecBufferInfo info{};
            const auto index = AMediaCodec_dequeueOutputBuffer(codec_->aac, &info, timeout);
            timeout = 0;
            if (index == AMEDIACODEC_INFO_TRY_AGAIN_LATER) return true;
            if (index == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) continue;
            if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
                auto *format = AMediaCodec_getOutputFormat(codec_->aac);
                int32_t rate = 0, channels = 0, encoding = 2;
                const auto valid = format && AMediaFormat_getInt32(format, "sample-rate", &rate)
                    && AMediaFormat_getInt32(format, "channel-count", &channels);
                if (format) {
                    log_(AMediaFormat_toString(format));
                    AMediaFormat_getInt32(format, "pcm-encoding", &encoding); AMediaFormat_delete(format);
                }
                if (!valid || rate != kSampleRate || channels != 2 || encoding != 2) {
                    log_("Unsupported MediaCodec PCM format"); return false;
                }
                continue;
            }
            if (index < 0) return false;
            size_t capacity = 0;
            auto *bytes = AMediaCodec_getOutputBuffer(codec_->aac, index, &capacity);
            const bool valid = info.offset >= 0 && info.size >= 0 && size_t(info.offset) <= capacity
                && size_t(info.size) <= capacity - size_t(info.offset) && info.size % 4 == 0;
            if (valid && info.size && bytes && !(info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG)) {
                std::vector<int16_t> pcm(size_t(info.size) / sizeof(int16_t));
                std::memcpy(pcm.data(), bytes + info.offset, info.size);
                report_pcm(pcm);
                write_pcm(pcm.data(), pcm.size() / 2, info.presentationTimeUs * 1000, generation, produced);
            }
            AMediaCodec_releaseOutputBuffer(codec_->aac, index, false);
            if (!valid || (info.size && !bytes)) return false;
        }
    };
    if (!drain(0)) return false;
    const auto index = AMediaCodec_dequeueInputBuffer(codec_->aac, 20000);
    if (index < 0) return false;
    size_t capacity = 0;
    auto *bytes = AMediaCodec_getInputBuffer(codec_->aac, index, &capacity);
    if (!bytes || size > capacity) { clear(); return false; }
    std::memcpy(bytes, data, size);
    if (AMediaCodec_queueInputBuffer(codec_->aac, index, 0, size, deadline / 1000, 0) != AMEDIA_OK) return false;
    return drain(10000);
}
} // namespace airplay
