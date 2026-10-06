// SPDX-License-Identifier: GPL-3.0-only
#include "../ffmpeg/ffmpeg_video.h"
#include "linux_video.h"

namespace airplay {
std::unique_ptr<VideoOutput> make_video_output(void *surface, const char *, const char *, VideoCallbacks callbacks) {
    const auto *options = static_cast<const AirplayLinuxVideoOptions *>(surface);
    return make_ffmpeg_video_output(std::move(callbacks),
        options ? LinuxVideoOptions{options->hardware, options->gpu_output} : LinuxVideoOptions{});
}
}
