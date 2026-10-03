// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "linux_video.h"
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <new>
#include <utility>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/buffer.h>
#include <libavutil/error.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}

#ifndef AV_CODEC_FLAG_COPY_OPAQUE
#error "Linux video requires FFmpeg 6 or newer (libavcodec >= 60)"
#endif

namespace airplay {
namespace {
constexpr int kMaxDimension = 4096;
constexpr size_t kMaxPacketBytes = 4 * 1024 * 1024;
constexpr size_t kMaxParameterBytes = 256 * 1024;
constexpr size_t kMaxNals = 4096;
constexpr AVRational kNanoseconds{1, 1000000000};

struct PacketTiming {
    int64_t deadline;
    uint64_t generation;
};
struct Nal {
    const uint8_t *data;
    size_t size;
    unsigned type;
};
struct PacketDeleter {
    void operator()(AVPacket *packet) const { av_packet_free(&packet); }
};

size_t start_code(const uint8_t *data, size_t size, size_t offset) {
    if (size - offset < 3 || data[offset] || data[offset + 1]) return 0;
    if (data[offset + 2] == 1) return 3;
    return size - offset >= 4 && data[offset + 2] == 0 && data[offset + 3] == 1 ? 4 : 0;
}

bool inspect_annex_b(const std::vector<uint8_t> &bytes, std::vector<Nal> &nals,
                     bool &picture, bool &keyframe) {
    size_t offset = 0;
    // Annex B permits leading_zero_8bits before the first start code.
    while (offset < bytes.size() && !start_code(bytes.data(), bytes.size(), offset)) {
        if (bytes[offset++]) return false;
    }
    if (offset == bytes.size()) return false;
    while (offset < bytes.size()) {
        const auto begin = offset + start_code(bytes.data(), bytes.size(), offset);
        offset = begin;
        while (offset < bytes.size() && !start_code(bytes.data(), bytes.size(), offset)) ++offset;
        size_t end = offset;
        while (end > begin && bytes[end - 1] == 0) --end; // trailing_zero_8bits
        if (end == begin || nals.size() >= kMaxNals) return false;
        const unsigned type = bytes[begin] & 31;
        if ((bytes[begin] & 0x80) || !type || type >= 24) return false;
        nals.push_back({bytes.data() + begin, end - begin, type});
        picture |= type >= 1 && type <= 5;
        keyframe |= type == 5;
    }
    return true;
}

AVPixelFormat software_format(AVCodecContext *, const AVPixelFormat *formats) {
    for (; *formats != AV_PIX_FMT_NONE; ++formats) {
        const auto *description = av_pix_fmt_desc_get(*formats);
        if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL)
            && sws_isSupportedInput(*formats)) return *formats;
    }
    return AV_PIX_FMT_NONE;
}

int bounded_buffer(AVCodecContext *context, AVFrame *frame, int flags) {
    if (frame->width < 1 || frame->height < 1 || frame->width > kMaxDimension
        || frame->height > kMaxDimension) return AVERROR(EINVAL);
    return avcodec_default_get_buffer2(context, frame, flags);
}

int colorspace(AVColorSpace space) {
    switch (space) {
        case AVCOL_SPC_BT709: return SWS_CS_ITU709;
        case AVCOL_SPC_FCC: return SWS_CS_FCC;
        case AVCOL_SPC_BT470BG:
        case AVCOL_SPC_SMPTE170M: return SWS_CS_ITU601;
        case AVCOL_SPC_SMPTE240M: return SWS_CS_SMPTE240M;
        case AVCOL_SPC_BT2020_NCL:
        case AVCOL_SPC_BT2020_CL: return SWS_CS_BT2020;
        default: return SWS_CS_DEFAULT;
    }
}
} // namespace

class LinuxVideo final : public VideoOutput {
public:
    explicit LinuxVideo(VideoCallbacks callbacks) : callbacks_(std::move(callbacks)) {}
    ~LinuxVideo() override { release(); }

    // The source's SPS owns the dimensions. A screen-size notification is not
    // a crop request and must not discard references during a rotation.
    void size(int, int) override {}

    void reset() override {
        // Recreate rather than flush: flush retains SPS/PPS from the old sender.
        // Drop delayed frames; resetting must never publish the previous stream.
        release();
        parameters_.clear();
        parameter_bytes_ = 0;
        waiting_for_keyframe_ = true;
        failed_ = false;
    }

    bool decode(const VideoPacket &input) override {
        if (failed_) return false;
        try {
            if (input.bytes.empty() || input.bytes.size() > kMaxPacketBytes)
                return fail("Invalid H.264 packet size");
            std::vector<Nal> nals;
            bool picture = false, keyframe = false;
            if (!inspect_annex_b(input.bytes, nals, picture, keyframe))
                return fail("Malformed H.264 Annex B packet");

            if (!picture || (waiting_for_keyframe_ && !keyframe)) {
                // UxPlay sends SPS/PPS in their own packet. libavcodec expects
                // complete access units, so pass headers with the next picture.
                for (const auto &nal : nals) {
                    if (nal.type != 7 && nal.type != 8) continue;
                    if (nal.size < 2) return fail("Truncated H.264 parameter set");
                    const auto duplicate = std::find_if(parameters_.begin(), parameters_.end(),
                        [&](const auto &saved) {
                            return saved.size() == nal.size && !std::memcmp(saved.data(), nal.data, nal.size);
                        });
                    if (duplicate != parameters_.end()) {
                        // Preserve update order even when the sender switches
                        // A -> B -> A using the same parameter-set identifier.
                        std::rotate(duplicate, duplicate + 1, parameters_.end());
                        continue;
                    }
                    if (nal.size + 4 > kMaxParameterBytes - parameter_bytes_)
                        return fail("Too many pending H.264 parameter sets");
                    parameters_.emplace_back(nal.data, nal.data + nal.size);
                    parameter_bytes_ += nal.size + 4;
                }
                return true;
            }

            if (!codec_ && !open()) return false;
            std::unique_ptr<AVPacket, PacketDeleter> packet(av_packet_alloc());
            if (!packet) return fail("Cannot allocate H.264 packet");
            const auto bytes = parameter_bytes_ + input.bytes.size();
            int status = av_new_packet(packet.get(), static_cast<int>(bytes));
            if (status < 0) return fail("Cannot allocate H.264 input", status);
            size_t offset = 0;
            for (const auto &parameter : parameters_) {
                const uint8_t prefix[] = {0, 0, 0, 1};
                std::memcpy(packet->data + offset, prefix, sizeof(prefix));
                offset += sizeof(prefix);
                std::memcpy(packet->data + offset, parameter.data(), parameter.size());
                offset += parameter.size();
            }
            std::memcpy(packet->data + offset, input.bytes.data(), input.bytes.size());
            // av_new_packet also zeroes AV_INPUT_BUFFER_PADDING_SIZE bytes.
            packet->pts = input.deadline;
            packet->dts = AV_NOPTS_VALUE;
            packet->time_base = kNanoseconds;
            if (keyframe) packet->flags |= AV_PKT_FLAG_KEY;
            packet->opaque_ref = av_buffer_alloc(sizeof(PacketTiming));
            if (!packet->opaque_ref) return fail("Cannot allocate H.264 frame timing");
            const PacketTiming timing{input.deadline, input.generation};
            std::memcpy(packet->opaque_ref->data, &timing, sizeof(timing));

            status = avcodec_send_packet(codec_, packet.get());
            if (status == AVERROR(EAGAIN)) {
                if (!receive()) return false;
                status = avcodec_send_packet(codec_, packet.get());
            }
            if (status < 0) return fail("H.264 packet rejected", status);
            parameters_.clear();
            parameter_bytes_ = 0;
            waiting_for_keyframe_ = false;
            return receive();
        } catch (const std::bad_alloc &) {
            return fail("Cannot allocate H.264 working memory");
        }
    }

    void drain() override {
        // Called continuously by player.cpp, not an end-of-stream operation.
        // Sending a null packet here would finalize every picture's decoder.
        if (codec_ && !failed_) receive();
    }

private:
    bool fail(const char *message, int error = 0) {
        failed_ = true;
        if (callbacks_.log) {
            if (!error) callbacks_.log(message);
            else {
                char detail[AV_ERROR_MAX_STRING_SIZE]{};
                char text[256]{};
                av_strerror(error, detail, sizeof(detail));
                std::snprintf(text, sizeof(text), "%s: %s", message, detail);
                callbacks_.log(text);
            }
        }
        return false;
    }

    bool open() {
        // Explicitly choose FFmpeg's native CPU decoder, never a device backend.
        const AVCodec *decoder = avcodec_find_decoder_by_name("h264");
        if (!decoder || decoder->id != AV_CODEC_ID_H264)
            return fail("FFmpeg software H.264 decoder is unavailable");
        codec_ = avcodec_alloc_context3(decoder);
        frame_ = av_frame_alloc();
        rgba_ = av_frame_alloc();
        if (!codec_ || !frame_ || !rgba_) return fail("Cannot allocate H.264 decoder");
        codec_->pkt_timebase = kNanoseconds;
        codec_->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
        // Slice threads avoid the extra frame latency of frame threading while
        // retaining normal H.264 picture reordering for streams with B frames.
        codec_->thread_count = 2;
        codec_->thread_type = FF_THREAD_SLICE;
        codec_->get_format = software_format;
        codec_->get_buffer2 = bounded_buffer;
        codec_->max_pixels = int64_t(kMaxDimension) * kMaxDimension;
        codec_->err_recognition = AV_EF_BITSTREAM | AV_EF_BUFFER | AV_EF_EXPLODE;
        const int status = avcodec_open2(codec_, decoder, nullptr);
        if (status < 0) return fail("Cannot open software H.264 decoder", status);
        if (callbacks_.log) callbacks_.log("FFmpeg software H.264 decoder ready; borrowed RGBA output");
        return true;
    }

    bool receive() {
        for (;;) {
            const int status = avcodec_receive_frame(codec_, frame_);
            if (status == AVERROR(EAGAIN)) return true;
            if (status < 0) return fail("H.264 frame decoding failed", status);
            const bool good = render();
            av_frame_unref(frame_);
            if (!good) return false;
        }
    }

    bool render() {
        const int width = frame_->width, height = frame_->height;
        if (width < 1 || height < 1 || width > kMaxDimension || height > kMaxDimension)
            return fail("Unsupported H.264 frame dimensions");
        if ((frame_->flags & AV_FRAME_FLAG_CORRUPT) || frame_->decode_error_flags)
            return fail("Corrupt H.264 frame discarded");
        if (!frame_->opaque_ref || frame_->opaque_ref->size != sizeof(PacketTiming))
            return fail("H.264 frame has no matching packet timing");
        PacketTiming timing{};
        std::memcpy(&timing, frame_->opaque_ref->data, sizeof(timing));

        if (rgba_->width != width || rgba_->height != height) {
            av_frame_unref(rgba_);
            rgba_->format = AV_PIX_FMT_RGBA;
            rgba_->width = width;
            rgba_->height = height;
            const int status = av_frame_get_buffer(rgba_, 32);
            if (status < 0) return fail("Cannot allocate RGBA video frame", status);
        }
        scaler_ = sws_getCachedContext(scaler_, width, height, static_cast<AVPixelFormat>(frame_->format),
            width, height, AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (!scaler_) return fail("Cannot create H.264 RGBA converter");
        const auto *coefficients = sws_getCoefficients(colorspace(frame_->colorspace));
        if (sws_setColorspaceDetails(scaler_, coefficients, frame_->color_range == AVCOL_RANGE_JPEG,
                coefficients, 1, 0, 1 << 16, 1 << 16) < 0)
            return fail("Unsupported H.264 video color space");
        const int rows = sws_scale(scaler_, frame_->data, frame_->linesize, 0, height,
                                    rgba_->data, rgba_->linesize);
        if (rows != height) return fail("Incomplete H.264 RGBA conversion");
        AirplayLinuxVideoFrame output{rgba_->data[0], rgba_->linesize[0], width, height};
        if (callbacks_.frame) callbacks_.frame(&output, width, height, timing.deadline, timing.generation);
        return true;
    }

    void release() {
        avcodec_free_context(&codec_);
        av_frame_free(&frame_);
        av_frame_free(&rgba_);
        sws_freeContext(scaler_);
        scaler_ = nullptr;
    }

    VideoCallbacks callbacks_;
    AVCodecContext *codec_ = nullptr;
    AVFrame *frame_ = nullptr;
    AVFrame *rgba_ = nullptr;
    SwsContext *scaler_ = nullptr;
    std::vector<std::vector<uint8_t>> parameters_;
    size_t parameter_bytes_ = 0;
    bool waiting_for_keyframe_ = true;
    bool failed_ = false;
};

std::unique_ptr<VideoOutput> make_video_output(void *, const char *, const char *, VideoCallbacks callbacks) {
    return std::make_unique<LinuxVideo>(std::move(callbacks));
}
} // namespace airplay
