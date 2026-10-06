// SPDX-License-Identifier: GPL-3.0-only
#pragma once
extern "C" {
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libswscale/swscale.h>
}
#include <cerrno>

namespace airplay {
inline int ffmpeg_colorspace(AVColorSpace space) {
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

class FFmpegColors {
public:
    ~FFmpegColors() { reset(); }
    FFmpegColors() = default;
    FFmpegColors(const FFmpegColors &) = delete;
    FFmpegColors &operator=(const FFmpegColors &) = delete;
    void reset() {
        sws_freeContext(scaler_); scaler_ = nullptr;
        av_frame_free(&rgba_);
        width_ = height_ = 0; format_ = AV_PIX_FMT_NONE;
        space_ = range_ = -1;
    }
    AVFrame *rgba() const { return rgba_; }
    int convert(const AVFrame &input) {
        auto format = static_cast<AVPixelFormat>(input.format);
        bool full = input.color_range == AVCOL_RANGE_JPEG;
        // YUVJ is the same plane layout with full range. swscale normalizes it
        // internally, so passing YUVJ to getCachedContext on every frame misses
        // its cache and repeatedly allocates/logs. Keep range explicit instead.
        switch (format) {
            case AV_PIX_FMT_YUVJ420P: format = AV_PIX_FMT_YUV420P; full = true; break;
            case AV_PIX_FMT_YUVJ422P: format = AV_PIX_FMT_YUV422P; full = true; break;
            case AV_PIX_FMT_YUVJ444P: format = AV_PIX_FMT_YUV444P; full = true; break;
            case AV_PIX_FMT_YUVJ440P: format = AV_PIX_FMT_YUV440P; full = true; break;
            case AV_PIX_FMT_YUVJ411P: format = AV_PIX_FMT_YUV411P; full = true; break;
            default: break;
        }
        if (!rgba_) rgba_ = av_frame_alloc();
        if (!rgba_) return AVERROR(ENOMEM);
        // Every pixel will be overwritten; allocate a fresh buffer when a queued
        // picture retains the old one, instead of copying old pixels first.
        if (rgba_->width != input.width || rgba_->height != input.height || !av_frame_is_writable(rgba_)) {
            av_frame_unref(rgba_);
            rgba_->format = AV_PIX_FMT_RGBA;
            rgba_->width = input.width; rgba_->height = input.height;
            const int status = av_frame_get_buffer(rgba_, 32);
            if (status < 0) return status;
        }
        const bool changed = !scaler_ || width_ != input.width || height_ != input.height || format_ != format;
        if (changed) {
            scaler_ = sws_getCachedContext(scaler_, input.width, input.height, format,
                input.width, input.height, AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
            if (!scaler_) return AVERROR(ENOMEM);
            width_ = input.width; height_ = input.height; format_ = format;
        }
        const int space = ffmpeg_colorspace(input.colorspace);
        if (changed || space_ != space || range_ != int(full)) {
            const auto *coefficients = sws_getCoefficients(space);
            const int status = sws_setColorspaceDetails(scaler_, coefficients, full,
                coefficients, 1, 0, 1 << 16, 1 << 16);
            if (status < 0) return status;
            space_ = space; range_ = full;
        }
        const int rows = sws_scale(scaler_, input.data, input.linesize, 0, input.height, rgba_->data, rgba_->linesize);
        return rows == input.height ? 0 : AVERROR(EINVAL);
    }
private:
    AVFrame *rgba_ = nullptr;
    SwsContext *scaler_ = nullptr;
    int width_ = 0, height_ = 0, space_ = -1, range_ = -1;
    AVPixelFormat format_ = AV_PIX_FMT_NONE;
};
} // namespace airplay
