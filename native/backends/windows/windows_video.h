// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstddef>
#include <cstdint>

struct IDXGIAdapter;
struct ID3D11Texture2D;

namespace airplay {
// Windows-only create options, borrowed during airplay_player_create.
// Use Flutter's adapter so its renderer can import the resulting textures.
struct WindowsVideoOptions {
    IDXGIAdapter *adapter = nullptr;
    bool gpu = false;
};
// Borrowed for the duration of AirplayCallbacks.frame. Either CPU RGBA pixels
// (top row first), or an immutable shared BGRA D3D11 texture. The host copies
// the pixels or retains a COM reference before returning from the callback.
struct WindowsVideoFrame {
    const uint8_t *pixels;
    size_t width, height, stride;
    ID3D11Texture2D *texture = nullptr;
};
} // namespace airplay
