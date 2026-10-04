// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace airplay {
inline bool windows_yuv420_to_rgba(const uint8_t *bytes, size_t length, size_t width,
                                  size_t height, size_t stride, bool bt709, bool full_range,
                                  std::vector<uint8_t> &rgba, bool p010) {
    const size_t sample_bytes = p010 ? 2 : 1;
    if (!bytes || !width || !height || width > 4096 || height > 4096 ||
        (width & 1) || (height & 1) || stride < width * sample_bytes || stride > 32768 ||
        length < stride * (height + height / 2)) return false;
    rgba.resize(width * height * 4);
    auto clip = [](int n) { return uint8_t(std::clamp(n, 0, 255)); };
    for (size_t y = 0; y < height; ++y) {
        for (size_t x = 0; x < width; ++x) {
            // P010 stores ten-bit samples in the high bits of little-endian words.
            // The Flutter RGBA texture is eight-bit; keep the high eight bits.
            const size_t high = p010 ? 1 : 0;
            int luma = bytes[y * stride + x * sample_bytes + high];
            const auto chroma = stride * height + (y / 2) * stride + (x & ~size_t(1)) * sample_bytes;
            int u = int(bytes[chroma + high]) - 128;
            int v = int(bytes[chroma + sample_bytes + high]) - 128;
            int c = full_range ? luma * 256 : std::max(0, luma - 16) * 298;
            const int rv = full_range ? (bt709 ? 403 : 359) : (bt709 ? 459 : 409);
            const int gu = full_range ? (bt709 ? 48 : 88) : (bt709 ? 55 : 100);
            const int gv = full_range ? (bt709 ? 120 : 183) : (bt709 ? 136 : 208);
            const int bu = full_range ? (bt709 ? 475 : 454) : (bt709 ? 541 : 516);
            auto *out = rgba.data() + (y * width + x) * 4;
            out[0] = clip((c + rv * v + 128) >> 8);
            out[1] = clip((c - gu * u - gv * v + 128) >> 8);
            out[2] = clip((c + bu * u + 128) >> 8);
            out[3] = 255;
        }
    }
    return true;
}
inline bool windows_nv12_to_rgba(const uint8_t *bytes, size_t length, size_t width,
    size_t height, size_t stride, bool bt709, bool full_range, std::vector<uint8_t> &rgba) {
    return windows_yuv420_to_rgba(bytes, length, width, height, stride, bt709, full_range, rgba, false);
}
inline bool windows_p010_to_rgba(const uint8_t *bytes, size_t length, size_t width,
    size_t height, size_t stride, bool bt709, bool full_range, std::vector<uint8_t> &rgba) {
    return windows_yuv420_to_rgba(bytes, length, width, height, stride, bt709, full_range, rgba, true);
}
} // namespace airplay
