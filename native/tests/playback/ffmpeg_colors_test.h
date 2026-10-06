// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../../backends/ffmpeg/ffmpeg_colors.h"
extern "C" {
#include <libavutil/log.h>
}
#include <array>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace airplay_test {
inline std::vector<std::string> color_logs;
inline void color_log(void *, int level, const char *format, va_list args) {
    if (level > AV_LOG_WARNING) return;
    char message[512]; std::vsnprintf(message, sizeof(message), format, args);
    color_logs.emplace_back(message);
}
inline void ffmpeg_colors_test() {
    struct Scope {
        AVFrame *frame = av_frame_alloc();
        Scope() { color_logs.clear(); av_log_set_callback(color_log); }
        ~Scope() { av_frame_free(&frame); av_log_set_callback(av_log_default_callback); }
    } scope;
    auto require = [](bool good, const char *message) { if (!good) throw std::runtime_error(message); };
    auto *frame = scope.frame;
    require(frame != nullptr, "Allocate color fixture");
    frame->width = 64; frame->height = 32; frame->format = AV_PIX_FMT_YUVJ420P;
    frame->colorspace = AVCOL_SPC_BT709; frame->color_range = AVCOL_RANGE_UNSPECIFIED;
    require(av_frame_get_buffer(frame, 32) == 0, "Allocate YUVJ fixture planes");
    std::memset(frame->data[0], 16, size_t(frame->linesize[0]) * frame->height);
    for (int i = 1; i < 3; ++i) std::memset(frame->data[i], 128, size_t(frame->linesize[i]) * frame->height / 2);
    airplay::FFmpegColors converter;
    require(converter.convert(*frame) == 0, "Convert full-range YUVJ");
    const auto initial_logs = color_logs.size();
    for (int i = 0; i < 60; ++i) {
        require(converter.convert(*frame) == 0, "Reuse YUVJ converter");
        const auto *pixel = converter.rgba()->data[0];
        require(pixel[0] >= 14 && pixel[0] <= 18 && pixel[3] == 255, "YUVJ preserves full-range black level");
    }
    require(color_logs.size() == initial_logs, "Repeated frames do not recreate/log the converter");
    for (const auto &message : color_logs)
        require(message.find("deprecated pixel format") == std::string::npos, "YUVJ uses explicit full range without deprecated format");
    frame->format = AV_PIX_FMT_YUV420P; frame->color_range = AVCOL_RANGE_JPEG;
    require(converter.convert(*frame) == 0 && color_logs.size() == initial_logs,
            "Equivalent explicit full-range layout reuses conversion state");
    frame->color_range = AVCOL_RANGE_MPEG;
    require(converter.convert(*frame) == 0 && converter.rgba()->data[0][0] < 3,
            "Range changes update conversion instead of retaining full range");
    auto *held = av_frame_clone(converter.rgba());
    require(held != nullptr, "Retain queued RGBA buffer");
    const auto held_frame = std::shared_ptr<AVFrame>(held, [](AVFrame *value) { av_frame_free(&value); });
    std::memset(frame->data[0], 100, size_t(frame->linesize[0]) * frame->height);
    std::memset(frame->data[1], 80, size_t(frame->linesize[1]) * frame->height / 2);
    std::memset(frame->data[2], 200, size_t(frame->linesize[2]) * frame->height / 2);
    require(converter.convert(*frame) == 0, "Convert BT709 color");
    require(held_frame->data[0][0] < 3 && held_frame->data[0][3] == 255,
            "Queued RGBA pixels survive subsequent conversion");
    std::array<uint8_t, 3> bt709{}; std::memcpy(bt709.data(), converter.rgba()->data[0], 3);
    frame->colorspace = AVCOL_SPC_SMPTE170M;
    require(converter.convert(*frame) == 0 && std::memcmp(bt709.data(), converter.rgba()->data[0], 3) != 0,
            "Matrix changes update colors without changing dimensions");
    converter.reset();
    require(held_frame->data[0][0] < 3, "Retained RGBA picture outlives converter reset");
    require(converter.convert(*frame) == 0, "Color conversion recovers after reset");
    std::puts("PASS: FFmpeg YUVJ cache reuse, full/limited range, color matrix and reset");
}
} // namespace airplay_test
