// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "platform.h"

namespace airplay {
// Native CPU decoding shared by Linux and the Windows HEVC fallback.
std::unique_ptr<VideoOutput> make_ffmpeg_video_output(VideoCallbacks callbacks);
}
