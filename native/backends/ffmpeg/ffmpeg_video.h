// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../../playback/platform.h"

namespace airplay {
// Software decoding remains available for fixtures and unsupported devices.
std::unique_ptr<VideoOutput> make_ffmpeg_video_output(VideoCallbacks callbacks);
#ifdef _WIN32
struct WindowsVideoOptions;
// Prefer D3D11 HEVC decoding on Flutter's adapter, with CPU fallback.
std::unique_ptr<VideoOutput> make_ffmpeg_video_output(VideoCallbacks callbacks, const WindowsVideoOptions *options);
#else
struct LinuxVideoOptions { bool hardware = false, gpu_output = false; };
std::unique_ptr<VideoOutput> make_ffmpeg_video_output(VideoCallbacks callbacks, const LinuxVideoOptions &options);
#endif
}
