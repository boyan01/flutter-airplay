// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "audio_decoder_tests.h"
#include "video_fixtures.h"
#include "hevc_fixtures.h"
#include <TargetConditionals.h>
#import <XCTest/XCTest.h>
#import <AVFAudio/AVFAudio.h>
#include <CoreVideo/CoreVideo.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <functional>
#include <stdexcept>
#include <string>
#include <thread>

namespace {
void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

struct DecodedFrame {
    int width = 0, height = 0;
    int64_t deadline = 0;
    uint64_t generation = 0;
    bool redBGRA = false;
};

// Pixel buffers are borrowed for the duration of the native callback. Copy only
// the observations needed by this fixture, and never retain their raw address.
DecodedFrame inspectFrame(void *frame, int width, int height, int64_t deadline, uint64_t generation) {
    DecodedFrame result{width, height, deadline, generation, false};
    if (!frame || width <= 0 || height <= 0) return result;
    auto pixel = static_cast<CVPixelBufferRef>(frame);
    if (CVPixelBufferGetPixelFormatType(pixel) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferGetWidth(pixel) != size_t(width) || CVPixelBufferGetHeight(pixel) != size_t(height) ||
        CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return result;
    const auto *bytes = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pixel));
    const auto stride = CVPixelBufferGetBytesPerRow(pixel);
    result.redBGRA = bytes && stride >= size_t(width) * 4;
    const std::array<std::array<int, 2>, 5> points{{
        {{0, 0}}, {{width - 1, 0}}, {{width / 2, height / 2}},
        {{0, height - 1}}, {{width - 1, height - 1}}
    }};
    if (result.redBGRA) for (const auto &point : points) {
        const auto *sample = bytes + size_t(point[1]) * stride + size_t(point[0]) * 4;
        result.redBGRA &= sample[0] < 30 && sample[1] < 30 && sample[2] > 200 && sample[3] > 200;
    }
    CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
    return result;
}
} // namespace

@interface MediaTests : XCTestCase
@end

@implementation MediaTests

- (void)runNativeChecks:(const std::function<void()> &)checks {
    try {
        checks();
    } catch (const std::exception &error) {
        XCTFail(@"Native media regression failed: %s", error.what());
    } catch (...) {
        XCTFail(@"Native media regression failed with an unknown C++ exception");
    }
}

- (void)testAudioDecodersProducePCMAndFlush {
    [self runNativeChecks:[] { check_audio_decoder(); }];
}

- (void)testH264PixelsOrientationResetAndGeneration {
    [self runNativeChecks:[] {
        using namespace airplay;
        std::mutex lock;
        std::vector<DecodedFrame> frames;
        auto video = make_video_output(nullptr, nullptr, nullptr, {
            [&](void *frame, int width, int height, int64_t deadline, uint64_t generation) {
                const auto inspected = inspectFrame(frame, width, height, deadline, generation);
                std::lock_guard<std::mutex> guard(lock);
                frames.push_back(inspected);
            }, [](const char *) {}
        });
        require(bool(video), "VideoToolbox output was not created");
        int64_t due = monotonic_ns() + 120000000;
        auto verify = [&](size_t count, int width, int height, int64_t deadline, uint64_t generation) {
            const auto until = monotonic_ns() + 2 * kSecond;
            while (monotonic_ns() < until) {
                video->drain();
                { std::lock_guard<std::mutex> guard(lock); if (frames.size() >= count) break; }
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            std::lock_guard<std::mutex> guard(lock);
            require(frames.size() == count, "Unexpected number of decoded H.264 frames");
            const auto &last = frames.back();
            require(last.width == width && last.height == height, "H.264 dimensions do not match orientation");
            require(last.redBGRA, "VideoToolbox BGRA pixels are not the synthetic red frame");
            require(last.deadline == deadline, "Video callback lost its scheduling deadline");
            require(last.generation == generation, "Video callback lost its session generation");
        };
        require(video->decode({{std::begin(landscape), std::end(landscape)}, due, 7}), "Landscape H.264 decode failed");
        verify(1, landscape_width, landscape_height, due, 7);
        video->reset();
        require(video->decode({{0, 0, 0, 1, 0x41, 0x01}, due + 1, 8}), "Non-keyframe recovery packet failed");
        {
            std::lock_guard<std::mutex> guard(lock);
            require(frames.size() == 1, "Reset emitted a frame before SPS/PPS and a new keyframe");
        }
        due = monotonic_ns() + 120000000;
        require(video->decode({{std::begin(portrait), std::end(portrait)}, due + 2, 8}), "Portrait H.264 decode after reset failed");
        verify(2, landscape_height, landscape_width, due + 2, 8);
        due = monotonic_ns() + 120000000;
        require(video->decode({{std::begin(landscape), std::end(landscape)}, due + 3, 8}), "SPS change H.264 decode failed");
        verify(3, landscape_width, landscape_height, due + 3, 8);
        video->reset();
        video->reset();
        due = monotonic_ns() + 120000000;
        require(video->decode({{std::begin(portrait), std::end(portrait)}, due + 4, 9}), "Repeated reset lost decoder recovery");
        verify(4, landscape_height, landscape_width, due + 4, 9);
        video->drain();
    }];
}

- (void)testHEVCPixelsOrientationMain10AndH264Reconnect {
    auto capability = airplay::make_video_output(nullptr, nullptr, nullptr, {
        [](void *, int, int, int64_t, uint64_t) {}, [](const char *) {}
    });
#if TARGET_OS_SIMULATOR
    if (!capability->supports_hevc()) { XCTSkip(@"HEVC hardware decoding is unavailable in this simulator"); return; }
#endif
    [self runNativeChecks:[&] {
        using namespace airplay;
        require(capability->supports_hevc(), "iPad HEVC hardware capability is not advertised");
        int count = 0, width = 0, height = 0;
        uint8_t color[3]{};
        auto video = make_video_output(nullptr, nullptr, nullptr, {
            [&](void *frame, int w, int h, int64_t, uint64_t generation) {
                require(generation == 17, "HEVC frame generation changed");
                auto pixel = static_cast<CVPixelBufferRef>(frame);
                require(CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess, "HEVC pixel lock failed");
                const auto *data = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pixel));
                std::copy_n(data, 3, color);
                CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
                ++count; width = w; height = h;
            }, [](const char *) {}
        });
        const auto feed = [&](const uint8_t *data, size_t size, int w, int h, int channel, bool hevc) {
            const int before = count;
            require(video->decode({{data, data + size}, monotonic_ns() + 120000000, 17, 0, hevc}), "Apple video access unit rejected");
            const auto until = monotonic_ns() + 2 * kSecond;
            while (count == before && monotonic_ns() < until) { video->drain(); std::this_thread::sleep_for(std::chrono::milliseconds(5)); }
            require(count == before + 1 && width == w && height == h, "HEVC dimensions or output count mismatch");
            require(color[channel] > 200, "HEVC BGRA color mismatch");
        };
        feed(hevc_fixtures::landscape, sizeof(hevc_fixtures::landscape), 640, 360, 2, true);
        feed(hevc_fixtures::portrait, sizeof(hevc_fixtures::portrait), 360, 640, 0, true);
        video->reset();
        feed(hevc_fixtures::uhd, sizeof(hevc_fixtures::uhd), 3840, 2160, 0, true);
        feed(hevc_fixtures::main10, sizeof(hevc_fixtures::main10), 640, 360, 1, true);
        feed(landscape, sizeof(landscape), 640, 360, 2, false);
    }];
}

- (void)testSilentRemoteIORendersAndRestarts {
    // The fixture only changes its application's session. Output samples are
    // zero and the host remains responsible for AVAudioSession deactivation.
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&error] ||
        ![session setActive:YES error:&error]) {
        XCTFail(@"Fixture AVAudioSession could not become active: %@", error.localizedDescription);
        return;
    }
    [self runNativeChecks:[] {
        using namespace airplay;
        constexpr size_t capacity = 4096;
        auto buffer = std::make_shared<airplay::AudioBuffer>(capacity);
        auto output = make_audio_output(buffer);
        require(bool(output), "RemoteIO output was not created");
        output->stop();
        std::vector<int16_t> silence(capacity * 2, 0);
        const int16_t silentFrame[] = {0, 0};
        for (int restart = 0; restart < 2; ++restart) {
            require(buffer->write(silence.data(), capacity, monotonic_ns(), buffer->generation()) == capacity,
                    "Silent PCM queue was not empty before RemoteIO start");
            require(output->start(), "RemoteIO start failed");
            require(output->start(), "RemoteIO duplicate start failed");
            bool rendered = false;
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (std::chrono::steady_clock::now() < until) {
                if (buffer->write(silentFrame, 1, monotonic_ns(), buffer->generation()) == 1) {
                    rendered = true;
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            output->stop();
            output->stop();
            require(rendered, "RemoteIO did not consume silent PCM through its render callback");
            buffer->flush();
            // There is no device consumer after stop, so the fixture may drain
            // the invalidated generation before filling the next session.
            buffer->read(silence.data(), capacity, monotonic_ns());
            require(std::all_of(silence.begin(), silence.end(), [](auto value) { return value == 0; }),
                    "Silent RemoteIO fixture produced nonzero PCM");
        }
    }];
}

@end
