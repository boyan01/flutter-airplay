// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "ffmpeg_video.h"
#include "windows_video.h"
#include "video_fixtures.h"
#include "hevc_fixtures.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <thread>

using namespace airplay;

namespace {
void check(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
struct Frame {
    int width, height;
    int64_t deadline;
    uint64_t generation;
    std::array<uint8_t, 4> pixel;
};
} // namespace

int main(int argc, char **argv) {
    try {
        const bool software = argc == 2 && std::strcmp(argv[1], "--software") == 0;
        check(argc == 1 || software, "Usage: windows_video_test [--software]");
        std::vector<Frame> frames;
        VideoCallbacks callbacks{
            [&](void *pointer, int width, int height, int64_t deadline, uint64_t generation) {
                const auto *image = static_cast<const WindowsVideoFrame *>(pointer);
                check(image && image->pixels && image->width == size_t(width) &&
                      image->height == size_t(height) && image->stride >= size_t(width) * 4,
                      "Windows callback borrows valid RGBA pixels");
                Frame frame{width, height, deadline, generation, {}};
                std::copy_n(image->pixels + size_t(height / 2) * image->stride + (width / 2) * 4,
                            4, frame.pixel.begin());
                frames.push_back(frame);
            }, [](const char *message) { std::puts(message); }
        };
        auto video = software ? make_ffmpeg_video_output(callbacks)
                              : make_video_output(nullptr, nullptr, nullptr, callbacks);
        check(video->supports_hevc(), "Windows advertises a usable HEVC decoder");
        int64_t anchor = 1234567890123;
        auto feed = [&](const uint8_t *data, size_t size, int width, int height, int channel, bool hevc) {
            const auto before = frames.size();
            constexpr int64_t tick = 16666667;
            for (int i = 0; i < 4; ++i)
                check(video->decode({{data, data + size}, anchor + i * tick, 77, 0, hevc}),
                      "Windows accepts the synthetic video access unit");
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (frames.size() == before && std::chrono::steady_clock::now() < until) {
                video->drain();
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            check(frames.size() > before, "Windows decoder publishes video pixels");
            for (size_t i = before; i < frames.size(); ++i) {
                const auto &frame = frames[i];
                check(frame.width == width && frame.height == height, "Windows source dimensions survive rotation");
                check(frame.generation == 77 && frame.deadline >= anchor &&
                      frame.deadline <= anchor + 3 * tick && (frame.deadline - anchor) % tick == 0,
                      "Windows output keeps originating packet timing and generation");
                check(frame.pixel[channel] > 200 && frame.pixel[(channel + 1) % 3] < 45 &&
                      frame.pixel[(channel + 2) % 3] < 45 && frame.pixel[3] == 255,
                      "Windows decoded RGBA pixels match the fixture color");
            }
            anchor += 1000000000;
        };
        feed(hevc_fixtures::landscape, sizeof(hevc_fixtures::landscape), 640, 360, 0, true);
        feed(hevc_fixtures::portrait, sizeof(hevc_fixtures::portrait), 360, 640, 2, true);
        video->reset();
        feed(hevc_fixtures::uhd, sizeof(hevc_fixtures::uhd), 3840, 2160, 2, true);
        feed(hevc_fixtures::main10, sizeof(hevc_fixtures::main10), 640, 360, 1, true);
        check(!video->decode({{0, 0, 1, 0x40}, anchor, 77, 0, true}), "Windows rejects truncated HEVC headers");
        video->reset();
        feed(hevc_fixtures::landscape, sizeof(hevc_fixtures::landscape), 640, 360, 0, true);
        if (!software) feed(landscape, sizeof(landscape), 640, 360, 0, false);
        std::puts("PASS: Windows HEVC RGBA landscape/portrait/4K/Main10, timing/generation, malformed recovery and reset");
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        return 1;
    }
}
