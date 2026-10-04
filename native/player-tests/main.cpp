// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "audio_decoder.h"
#include "audio_clock_tests.h"
#include <cstdio>
#include "audio_fixtures.h"
#include "audio_decoder_tests.h"
#include "video_fixtures.h"
#include "reorder_fixtures.h"
#include <CoreVideo/CoreVideo.h>
#include <stdexcept>
#include <thread>
#include <filesystem>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <cstring>
using namespace airplay;
void check(bool condition, const char *description) { if (!condition) throw std::runtime_error(description); }
int main() {
    try {
        check_audio_clock();
        check_audio_decoder();
        Timeline timeline;
        check(timeline.deadline(10000000000, 1000000000) == 1080000000, "first packet anchor");
        check(timeline.deadline(10010000000, 1100000000) == 1090000000, "audio/video preserve timestamp difference");
        timeline.reset();
        check(timeline.deadline(5, 2000000000) == 2080000000, "new session clears clock anchor");
        AudioBuffer buffer(8);
        int16_t input[] = {1000,-1000,2000,-2000,3000,-3000}, output[6];
        const int64_t due = 1000000000;
        check(buffer.write(input, 3, due, buffer.generation()) == 3, "PCM enqueue");
        buffer.read(output, 3, due - 10000000);
        check(output[0] == 0 && output[4] == 0, "future audio produces silence");
        buffer.volume(-6.0206f); buffer.read(output, 3, due);
        check(std::abs(output[0]-500) <= 1 && std::abs(output[5]+1500) <= 1, "stereo gain and scheduled output");
        buffer.volume(0);
        buffer.write(input, 3, due, buffer.generation()); buffer.flush();
        buffer.write(input, 3, due, buffer.generation()); buffer.read(output, 3, due);
        check(output[0] == 1000 && output[4] == 3000, "flush rejects prior session and keeps new audio");
        check(buffer.stale_drops() == 3 && buffer.late_drops() == 0, "diagnostics distinguish flushed PCM from late PCM");
        buffer.write(input, 3, due, buffer.generation()); buffer.read(output, 3, due+10000000);
        check(output[0] == 0 && output[4] == 0, "late packets are discarded");
        check(buffer.late_drops() == 3 && buffer.stale_drops() == 3, "diagnostics count discarded PCM frames");
        AudioBuffer concurrent(64);
        std::thread producer([&] {
            int16_t sample[] = {1234, -1234};
            for (int i = 0; i < 10000; ++i) {
                while (!concurrent.write(sample, 1, due + int64_t(i) * kSecond / kSampleRate, concurrent.generation()))
                    std::this_thread::yield();
            }
        });
        int bad = 0;
        for (int i = 0; i < 10000;) {
            int16_t sample[2]; concurrent.read(sample, 1, due + int64_t(i) * kSecond / kSampleRate);
            if (sample[0]) { bad += sample[0] != 1234 || sample[1] != -1234; ++i; }
            else std::this_thread::yield();
        }
        producer.join(); check(!bad, "SPSC PCM wraparound under concurrent producer/output");
        std::vector<uint8_t> annex{0,0,0,1,0x67,3,4,0,0,1,0x68,5,0,0,0,1,0x65,6};
        auto nals = split_nals(annex.data(), annex.size());
        check(nals.size() == 3 && nals[0].size() == 3 && nals[2][0] == 0x65, "Annex B three/four byte prefixes");
        int frames = 0, video_width = 0, video_height = 0;
        auto video = make_video_output(nullptr, nullptr, nullptr, {
            [&](void *frame, int w, int h, int64_t, uint64_t generation) {
                check(frame && generation == 7, "video generation and decoded buffer");
                auto image = static_cast<CVPixelBufferRef>(frame);
                check(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA, "Flutter-compatible BGRA");
                CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
                auto *pixels = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(image));
                check(pixels && pixels[2] > 200 && pixels[1] < 30 && pixels[0] < 30, "decoded pixels are red");
                CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
                ++frames; video_width = w; video_height = h;
            }, [](const char *) {}
        });
        check(video->decode({{std::begin(landscape), std::end(landscape)}, monotonic_ns(), 7}), "decode landscape H.264");
        video->drain();
        check(frames == 1 && video_width == landscape_width && video_height == landscape_height, "real landscape dimensions");
        video->reset();
        check(video->decode({{0,0,0,1,0x41,0x01}, due, 7}) && frames == 1, "reset waits for a keyframe");
        check(video->decode({{std::begin(portrait), std::end(portrait)}, monotonic_ns(), 7}), "decode portrait after reset");
        video->drain();
        check(frames == 2 && video_width == landscape_height && video_height == landscape_width, "rotation creates new decoder dimensions");
        check(video->decode({{std::begin(landscape), std::end(landscape)}, monotonic_ns(), 7}), "changed SPS without explicit reset");
        video->drain();
        check(frames == 3 && video_width == landscape_width, "SPS change replaces decoder session");
        {
            using namespace reorder_fixtures;
            const auto start = monotonic_ns(), first_due = start + 80000000;
            constexpr int64_t period = kSecond / 60;
            int sent = 0, presented = 0, early = 0, backwards = 0;
            int64_t previous = 0;
            auto reordered = make_video_output(nullptr, nullptr, nullptr, {
                [&](void *, int, int, int64_t pts, uint64_t) {
                    if (pts < first_due + 16 * period || pts >= first_due + 76 * period) return;
                    ++presented;
                    early += pts > monotonic_ns() + 2000000;
                    backwards += previous && pts <= previous;
                    previous = pts;
                }, [](const char *) {}
            });
            while (monotonic_ns() < start + 96 * period + 300000000) {
                const auto now = monotonic_ns();
                if (sent < 96 && now >= start + sent * period) {
                    const auto &packet = bframes_packets[sent++];
                    check(reordered->decode({{bframes_data + packet[0], bframes_data + packet[0] + packet[1]},
                        first_due + packet[2] * period, 9}), "decode reordered H.264 stream");
                }
                reordered->drain();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            std::printf("Mac B-frame output: presented=%d/60 early=%d backwards=%d\n", presented, early, backwards);
            check(presented >= 58 && !early && !backwards, "Mac presents B-frames by timestamp without early or backwards output");
        }
        const auto directory = std::filesystem::temp_directory_path() / ("airplay-player-test-" + std::to_string(getpid()));
        std::filesystem::create_directories(directory);
        const auto key = (directory / "pairing.pem").string();
        const uint8_t identity[] = {2,0,0,0,0,1};
        for (int session = 0; session < 3; ++session) {
            AirplayCallbacks callbacks{};
            auto *player = airplay_player_create(callbacks, nullptr, nullptr, nullptr);
            check(player, "create receiver with platform adapters");
            const int request_height = session == 0 ? 1080 : session == 1 ? 720 : 1440;
            const int request_width = request_height * 16 / 9;
            check(!airplay_player_set_video_size(player, 0, request_height), "reject zero request size");
            check(!airplay_player_set_video_size(player, 4097, request_height), "reject oversized request");
            if (session != 0) check(airplay_player_set_video_size(player, request_width, request_height), "configure requested quality");
            char error[512];
            check(airplay_player_start(player, "Synthetic Receiver", identity, key.c_str(), error, sizeof(error)), error);
            check(!airplay_player_set_video_size(player, 1280, 720), "cannot mutate a running receiver request");
            const auto port = airplay_player_port(player);
            check(port != 0, "dynamic receiver port");
            const auto count = airplay_player_txt(player, true, nullptr, 0);
            std::vector<uint8_t> txt(count); airplay_player_txt(player, true, txt.data(), txt.size());
            const std::string records(txt.begin(), txt.end());
            check(records.find("cn=1,2,3") != std::string::npos && records.find("cn=0,") == std::string::npos, "advertise only implemented audio codecs");
            int client = socket(AF_INET, SOCK_STREAM, 0);
            sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(port);
            check(connect(client, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0, "loopback listener connect");
            timeval timeout{2,0}; setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            const char request[] = "GET /info RTSP/1.0\r\nCSeq: 1\r\n\r\n";
            check(send(client, request, strlen(request), 0) == int(strlen(request)), "send synthetic RTSP request");
            std::string response;
            size_t header_end = std::string::npos, body_length = 0;
            while (true) {
                char chunk[4096]; const auto received = recv(client, chunk, sizeof(chunk), 0);
                check(received > 0, "receive complete info response");
                response.append(chunk, size_t(received));
                header_end = response.find("\r\n\r\n");
                if (header_end == std::string::npos) continue;
                const auto length = response.find("Content-Length: ");
                check(length < header_end, "info response has body length");
                body_length = std::stoul(response.substr(length + strlen("Content-Length: ")));
                if (response.size() >= header_end + 4 + body_length) break;
            }
            close(client);
            check(response.find("200 OK") < header_end, "receive real RTSP response");
            const auto data = CFDataCreate(nullptr, reinterpret_cast<const UInt8 *>(response.data() + header_end + 4), body_length);
            const auto info = CFPropertyListCreateWithData(nullptr, data, kCFPropertyListImmutable, nullptr, nullptr);
            CFRelease(data);
            check(info && CFGetTypeID(info) == CFDictionaryGetTypeID(), "decode advertised info plist");
            int64_t features = 0;
            const auto feature_value = static_cast<CFNumberRef>(CFDictionaryGetValue(static_cast<CFDictionaryRef>(info), CFSTR("features")));
            check(feature_value && CFNumberGetValue(feature_value, kCFNumberSInt64Type, &features), "numeric AirPlay features");
            check(bool((uint64_t(features) >> 42) & 1) == video->supports_hevc(),
                  "ScreenMultiCodec advertisement matches platform HEVC support");
            const auto displays = static_cast<CFArrayRef>(CFDictionaryGetValue(static_cast<CFDictionaryRef>(info), CFSTR("displays")));
            check(displays && CFArrayGetCount(displays) > 0, "advertised display exists");
            const auto display = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(displays, 0));
            auto number = [&](CFStringRef key) {
                int value = 0;
                const auto item = static_cast<CFNumberRef>(CFDictionaryGetValue(display, key));
                check(item && CFNumberGetValue(item, kCFNumberIntType, &value), "numeric display property");
                return value;
            };
            check(number(CFSTR("width")) == request_width && number(CFSTR("height")) == request_height,
                  "receiver advertises selected quality, including unchanged default");
            check(number(CFSTR("maxFPS")) == 60, "quality retains 60 FPS capability");
            CFRelease(info);
            airplay_player_destroy(player);
        }
        std::filesystem::remove_all(directory);
        std::puts("PASS: continuous audio clock, common timeline, PCM scheduling/gain/flush/late drop, Annex B, AAC/ALAC/AAC-ELD decode and FLUSH, VideoToolbox pixels/rotation/keyframe recovery, receiver stop/restart/TXT/RTSP");
    } catch (const std::exception &e) { std::fprintf(stderr, "FAIL: %s\n", e.what()); return 1; }
}
