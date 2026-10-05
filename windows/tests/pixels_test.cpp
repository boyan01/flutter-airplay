// SPDX-License-Identifier: GPL-3.0-only
#include "windows_pixels.h"
#include "../../native/player/video_quality.h"
#undef NDEBUG
#include <cassert>
#include <cstdio>

int main() {
    for (const auto* quality : airplay::video_qualities) assert(airplay::valid_video_quality(quality));
    assert(!airplay::valid_video_quality("invalid"));
    assert(!airplay::valid_video_quality(""));
    for (const auto& size : std::array<std::array<int, 2>, 4>{{{1280, 720}, {1920, 1080}, {2560, 1440}, {3840, 2160}}}) {
        const auto height = airplay::requested_video_height(std::to_string(size[1]), 1080);
        assert(height == size[1]);
        assert(airplay::requested_video_width(height) == size[0]);
    }
    assert(airplay::requested_video_height("auto", 2670) == 2160);
    assert(airplay::requested_video_height("auto", 1081) == 1080);
    assert(airplay::requested_video_height("auto", 0) == 480);

    std::vector<uint8_t> rgba;
    const uint8_t black[] = {16, 16, 16, 16, 128, 128};
    assert(airplay::windows_nv12_to_rgba(black, sizeof(black), 2, 2, 2, false, false, rgba));
    for (size_t i = 0; i < rgba.size(); i += 4) assert(rgba[i] == 0 && rgba[i + 1] == 0 && rgba[i + 2] == 0 && rgba[i + 3] == 255);
    const uint8_t white[] = {235, 235, 235, 235, 128, 128};
    assert(airplay::windows_nv12_to_rgba(white, sizeof(white), 2, 2, 2, true, false, rgba));
    assert(rgba[0] == 255 && rgba[1] == 255 && rgba[2] == 255);
    const uint8_t red_with_padding[] = {81, 81, 0, 0, 81, 81, 0, 0, 90, 240, 0, 0};
    assert(airplay::windows_nv12_to_rgba(red_with_padding, sizeof(red_with_padding), 2, 2, 4, false, false, rgba));
    assert(rgba[0] >= 250 && rgba[1] <= 2 && rgba[2] <= 2);
    const uint8_t full_white[] = {255, 255, 255, 255, 128, 128};
    assert(airplay::windows_nv12_to_rgba(full_white, sizeof(full_white), 2, 2, 2, true, true, rgba));
    assert(rgba[0] == 255 && rgba[1] == 255 && rgba[2] == 255);
    assert(!airplay::windows_nv12_to_rgba(black, 5, 2, 2, 2, false, false, rgba));
    assert(!airplay::windows_nv12_to_rgba(black, 6, 2, 2, 1, false, false, rgba));
    assert(!airplay::windows_nv12_to_rgba(black, 6, 4098, 2, 4098, false, false, rgba));
    assert(!airplay::windows_nv12_to_rgba(nullptr, 6, 2, 2, 2, false, false, rgba));
    const uint8_t p010_red[] = {0,81,0,81,0,81,0,81,0,90,0,240};
    assert(airplay::windows_p010_to_rgba(p010_red, sizeof(p010_red), 2, 2, 4, false, false, rgba));
    assert(rgba[0] >= 250 && rgba[1] <= 2 && rgba[2] <= 2 && rgba[3] == 255);
    assert(!airplay::windows_p010_to_rgba(p010_red, sizeof(p010_red)-1, 2, 2, 4, false, false, rgba));
    assert(!airplay::windows_p010_to_rgba(p010_red, sizeof(p010_red), 2, 2, 2, false, false, rgba));
    // Differentially protect SIMD rounding, clipping, channel order, range,
    // P010 high-byte handling, unaligned input and padded rows, including 4K.
    uint32_t random = 17;
    for (const auto width : {size_t(2), size_t(4), size_t(12), size_t(994), size_t(3840)}) {
        const size_t height = width == 3840 ? 2160 : 8;
        for (const bool p010 : {false, true}) for (const bool padded : {false, true}) {
            const size_t stride = width * (p010 ? 2 : 1) + (padded ? 8 : 0);
            std::vector<uint8_t> input(1 + stride * (height + height / 2));
            for (auto &byte : input) { random = random * 1664525 + 1013904223; byte = uint8_t(random >> 24); }
            for (const bool bt709 : {false, true}) for (const bool full : {false, true}) {
                std::vector<uint8_t> reference, accelerated;
                assert(airplay::windows_yuv420_to_rgba_scalar(input.data() + 1, input.size() - 1,
                    width, height, stride, bt709, full, reference, p010));
                assert(airplay::windows_yuv420_to_rgba(input.data() + 1, input.size() - 1,
                    width, height, stride, bt709, full, accelerated, p010));
                assert(reference == accelerated);
                assert(!airplay::windows_yuv420_to_rgba(input.data() + 1, input.size() - 2,
                    width, height, stride, bt709, full, accelerated, p010));
            }
        }
    }
    std::puts("NV12/P010 color, stride, range and malformed-buffer regressions passed");
}
