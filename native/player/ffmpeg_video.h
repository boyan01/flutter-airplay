// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "platform.h"

namespace airplay {
// Native CPU decoding shared by Linux and the Windows software fallback.
std::unique_ptr<VideoOutput> make_ffmpeg_video_output(VideoCallbacks callbacks);
#ifdef _WIN32
struct WindowsVideoOptions;
// Prefer D3D11 HEVC decoding on Flutter's adapter, with CPU fallback.
std::unique_ptr<VideoOutput> make_ffmpeg_video_output(VideoCallbacks callbacks, const WindowsVideoOptions *options);
#endif
}
