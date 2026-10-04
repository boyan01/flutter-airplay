// SPDX-License-Identifier: GPL-3.0-only
#include "windows_pixels.h"
#undef NDEBUG
#include <cassert>
#include <cstdio>

int main() {
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
    std::puts("NV12/P010 color, stride, range and malformed-buffer regressions passed");
}
