// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstddef>
#include <cstdint>

namespace airplay {
// Borrowed for the duration of AirplayCallbacks.frame. RGBA, top row first.
// The Flutter host copies the pixels before returning from the callback.
struct WindowsVideoFrame {
    const uint8_t *pixels;
    size_t width, height, stride;
};
} // namespace airplay
