// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../../playback/platform.h"

namespace airplay {
// Playback time is injectable independently of asynchronous codec execution.
std::unique_ptr<VideoOutput> make_apple_video_output(VideoCallbacks callbacks,
    std::function<int64_t()> clock = {});
} // namespace airplay
