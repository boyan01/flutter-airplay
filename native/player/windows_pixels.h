// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace airplay {
inline bool windows_nv12_to_rgba(const uint8_t *bytes, size_t length, size_t width,
                                  size_t height, size_t stride, bool bt709, bool full_range,
                                  std::vector<uint8_t> &rgba) {
    if (!bytes || !width || !height || width > 4096 || height > 4096 ||
        (width & 1) || (height & 1) || stride < width || stride > 16384 ||
        length < stride * (height + height / 2)) return false;
    rgba.resize(width * height * 4);
    auto clip = [](int n) { return uint8_t(std::clamp(n, 0, 255)); };
    for (size_t y = 0; y < height; ++y) {
        for (size_t x = 0; x < width; ++x) {
            int luma = bytes[y * stride + x];
            int u = int(bytes[stride * height + (y / 2) * stride + (x & ~size_t(1))]) - 128;
            int v = int(bytes[stride * height + (y / 2) * stride + (x & ~size_t(1)) + 1]) - 128;
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
} // namespace airplay
