// SPDX-License-Identifier: GPL-3.0-only
// AAC configuration derived from jqssun/android-airplay-server;
// see THIRD_PARTY_NOTICES.md and android/NOTICE.
#include "audio_decoder.h"
#include "alac_decoder.h"
#include <cstdio>
#include <cstring>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libswresample/swresample.h>
}

namespace airplay {
namespace {
void log_error(const std::function<void(const char *)> &log, const char *operation, int error) {
    char detail[AV_ERROR_MAX_STRING_SIZE]{};
    char message[192]{};
    av_strerror(error, detail, sizeof(detail));
    std::snprintf(message, sizeof(message), "%s: %s", operation, detail);
    log(message);
}
} // namespace

struct AudioDecoder::Codec {
    std::unique_ptr<AlacDecoder> alac;
    AVCodecContext *aac = nullptr;
    AVPacket *packet = nullptr;
    AVFrame *frame = nullptr;
    SwrContext *resampler = nullptr;
    ~Codec() {
        swr_free(&resampler);
        av_frame_free(&frame);
        av_packet_free(&packet);
        avcodec_free_context(&aac);
    }
};

AudioDecoder::AudioDecoder(std::shared_ptr<AudioBuffer> buffer, std::function<void(const char *)> log)
    : buffer_(std::move(buffer)), log_(std::move(log)) {}
AudioDecoder::~AudioDecoder() = default;
void AudioDecoder::clear() { codec_.reset(); }

bool AudioDecoder::open() {
    auto candidate = std::make_unique<Codec>();
    if (ct_ == 2) {
        candidate->alac = std::make_unique<AlacDecoder>();
        if (!candidate->alac->open(spf_)) {
            log_("Unable to configure Apple ALAC decoder");
            return false;
        }
    } else {
        if ((ct_ != 4 && ct_ != 8) || (ct_ == 4 && spf_ != 960 && spf_ != 1024)
            || (ct_ == 8 && spf_ != 480 && spf_ != 512)) {
            log_("Unsupported AAC samples per packet");
            return false;
        }
        // Use the tested floating-point decoder and its planar float output.
        const auto *implementation = avcodec_find_decoder_by_name("aac");
        if (!implementation || implementation->id != AV_CODEC_ID_AAC
            || (implementation->capabilities & AV_CODEC_CAP_DELAY)) {
            log_("Native low-delay FFmpeg AAC decoder is unavailable");
            return false;
        }
        candidate->aac = avcodec_alloc_context3(implementation);
        candidate->packet = av_packet_alloc();
        candidate->frame = av_frame_alloc();
        if (!candidate->aac || !candidate->packet || !candidate->frame) {
            log_("Unable to allocate FFmpeg AAC decoder");
            return false;
        }
        auto *context = candidate->aac;
        context->sample_rate = kSampleRate;
        av_channel_layout_default(&context->ch_layout, 2);
        context->request_sample_fmt = AV_SAMPLE_FMT_FLTP;
        context->thread_count = 1;
        context->err_recognition = AV_EF_EXPLODE;
        context->pkt_timebase = {1, int(kSecond)};
        const uint8_t aac[] = {0x12, uint8_t(spf_ == 960 ? 0x14 : 0x10)};
        const uint8_t eld[] = {0xf8, 0xe8, uint8_t(spf_ == 512 ? 0x40 : 0x50), 0};
        context->extradata_size = ct_ == 8 ? sizeof(eld) : sizeof(aac);
        context->extradata = static_cast<uint8_t *>(
            av_mallocz(context->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE));
        if (!context->extradata) {
            log_("Unable to allocate AAC configuration");
            return false;
        }
        std::memcpy(context->extradata, ct_ == 8 ? eld : aac, context->extradata_size);
        const int status = avcodec_open2(context, implementation, nullptr);
        if (status < 0) {
            log_error(log_, "Unable to open FFmpeg AAC decoder", status);
            return false;
        }
    }
    codec_ = std::move(candidate);
    log_(ct_ == 2 ? "Apple ALAC decoder ready" : ct_ == 8
        ? "FFmpeg AAC-ELD decoder ready" : "FFmpeg AAC decoder ready");
    return true;
}

bool AudioDecoder::decode_packet(const uint8_t *data, size_t size, int64_t deadline,
                                 uint64_t generation, bool *produced) {
    std::vector<int16_t> pcm;
    if (codec_->alac) {
        if (!codec_->alac->decode(data, size, pcm)) {
            log_("Malformed ALAC packet; resetting decoder");
            return false;
        }
        write_pcm(pcm.data(), pcm.size() / 2, deadline, generation, produced);
        return true;
    }

    auto *packet = codec_->packet;
    av_packet_unref(packet);
    int status = av_new_packet(packet, int(size));
    if (status < 0) {
        log_error(log_, "Unable to allocate AAC packet", status);
        return false;
    }
    // av_new_packet provides the zero padding required by FFmpeg's bit reader.
    std::memcpy(packet->data, data, size);
    packet->pts = packet->dts = deadline;
    packet->duration = int64_t(spf_) * kSecond / kSampleRate;
    status = avcodec_send_packet(codec_->aac, packet);
    av_packet_unref(packet);
    if (status < 0) {
        log_error(log_, "Invalid AAC packet; resetting decoder", status);
        return false;
    }

    // This decoder has no packet delay and is drained fully before another
    // packet is sent. Every output here therefore retains this packet's
    // deadline and generation, including multiple access units in one packet.
    // Stage PCM until the whole packet succeeds so malformed trailing data
    // cannot leave partially accepted audio in the playback queue.
    for (;;) {
        auto *frame = codec_->frame;
        av_frame_unref(frame);
        status = avcodec_receive_frame(codec_->aac, frame);
        if (status == AVERROR(EAGAIN)) break;
        if (status < 0) {
            log_error(log_, "Malformed AAC packet; resetting decoder", status);
            return false;
        }
        const AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        if (frame->sample_rate != kSampleRate || frame->format != AV_SAMPLE_FMT_FLTP
            || av_channel_layout_compare(&frame->ch_layout, &stereo) != 0
            || frame->nb_samples != spf_
            || (frame->flags & AV_FRAME_FLAG_CORRUPT)) {
            log_("Unsupported or corrupt FFmpeg AAC output; resetting decoder");
            return false;
        }
        // Bound decoded memory even for packets containing many tiny AUs.
        if (pcm.size() / 2 + size_t(frame->nb_samples) > 16384) {
            log_("AAC packet exceeds decoded frame limit; resetting decoder");
            return false;
        }
        if (!codec_->resampler) {
            AVChannelLayout output = AV_CHANNEL_LAYOUT_STEREO;
            status = swr_alloc_set_opts2(&codec_->resampler, &output, AV_SAMPLE_FMT_S16,
                kSampleRate, &frame->ch_layout, AV_SAMPLE_FMT_FLTP, kSampleRate, 0, nullptr);
            if (status >= 0) status = swr_init(codec_->resampler);
            if (status < 0) {
                log_error(log_, "Unable to configure AAC PCM conversion", status);
                return false;
            }
        }
        const auto offset = pcm.size();
        pcm.resize(offset + size_t(frame->nb_samples) * 2);
        uint8_t *output[] = {reinterpret_cast<uint8_t *>(pcm.data() + offset)};
        const uint8_t *input[] = {frame->extended_data[0], frame->extended_data[1]};
        status = swr_convert(codec_->resampler, output, frame->nb_samples, input, frame->nb_samples);
        if (status < 0) {
            log_error(log_, "AAC PCM conversion failed", status);
            return false;
        }
        if (status != frame->nb_samples || swr_get_delay(codec_->resampler, kSampleRate) != 0) {
            log_("Unexpected AAC PCM conversion delay; resetting decoder");
            return false;
        }
    }
    if (!pcm.empty()) write_pcm(pcm.data(), pcm.size() / 2, deadline, generation, produced);
    return true;
}
} // namespace airplay
