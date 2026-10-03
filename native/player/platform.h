// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "player.h"
#include "timeline.h"
#include <functional>
#include <memory>
#include <vector>

namespace airplay {
struct VideoPacket {
    std::vector<uint8_t> bytes;
    int64_t deadline = 0;
    uint64_t generation = 0;
};
class VideoOutput {
public:
    virtual ~VideoOutput() = default;
    virtual void size(int width, int height) = 0;
    virtual bool decode(const VideoPacket &) = 0;
    virtual void drain() = 0;
    virtual void reset() = 0;
};
class AudioOutput {
public:
    virtual ~AudioOutput() = default;
    virtual bool start() = 0;
    virtual void stop() = 0;
};
struct VideoCallbacks {
    std::function<void(void *, int, int, int64_t, uint64_t)> frame;
    std::function<void(const char *)> log;
};
std::unique_ptr<VideoOutput> make_video_output(void *surface, const char *decoder,
                                             const char *fallback, VideoCallbacks callbacks);
std::unique_ptr<AudioOutput> make_audio_output(std::shared_ptr<AudioBuffer>);

// H.264 Annex B input from UxPlay; also accepts three-byte start codes.
inline std::vector<std::vector<uint8_t>> split_nals(const uint8_t *data, size_t size) {
    std::vector<std::vector<uint8_t>> result;
    auto start_code = [&](size_t i) -> size_t {
        if (i + 3 <= size && data[i] == 0 && data[i + 1] == 0) {
            if (data[i + 2] == 1) return 3;
            if (i + 4 <= size && data[i + 2] == 0 && data[i + 3] == 1) return 4;
        }
        return 0;
    };
    size_t begin = size;
    for (size_t i = 0; i < size;) {
        auto length = start_code(i);
        if (!length) { ++i; continue; }
        if (begin < i) result.emplace_back(data + begin, data + i);
        begin = i + length; i = begin;
    }
    if (begin < size) result.emplace_back(data + begin, data + size);
    return result;
}
} // namespace airplay
