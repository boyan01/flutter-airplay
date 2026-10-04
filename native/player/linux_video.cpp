// SPDX-License-Identifier: GPL-3.0-only
#include "ffmpeg_video.h"

namespace airplay {
std::unique_ptr<VideoOutput> make_video_output(void *, const char *, const char *, VideoCallbacks callbacks) {
    return make_ffmpeg_video_output(std::move(callbacks));
}
}
