// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "audio_decoder.h"
#include "audio_clock_tests.h"
#include <cstdio>
#include "audio_fixtures.h"
#include "audio_decoder_tests.h"
#include "video_fixtures.h"
#include "linux_video.h"
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
        buffer.write(input, 3, due, buffer.generation()); buffer.read(output, 3, due+10000000);
        check(output[0] == 0 && output[4] == 0, "late packets are discarded");
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
                auto *image = static_cast<const AirplayLinuxVideoFrame *>(frame);
                auto *pixels = image->data;
                check(image->stride == w * 4 && image->width == w && image->height == h, "Flutter-compatible RGBA shape");
                check(pixels && pixels[0] > 200 && pixels[1] < 30 && pixels[2] < 30 && pixels[3] == 255, "decoded pixels are opaque red");
                ++frames; video_width = w; video_height = h;
            }, [](const char *) {}
        });
        check(video->decode({{std::begin(landscape), std::end(landscape)}, due, 7}), "decode landscape H.264");
        check(frames == 1 && video_width == landscape_width && video_height == landscape_height, "real landscape dimensions");
        video->reset();
        check(video->decode({{0,0,0,1,0x41,0x01}, due, 7}) && frames == 1, "reset waits for a keyframe");
        check(video->decode({{std::begin(portrait), std::end(portrait)}, due, 7}), "decode portrait after reset");
        check(frames == 2 && video_width == landscape_height && video_height == landscape_width, "rotation creates new decoder dimensions");
        check(video->decode({{std::begin(landscape), std::end(landscape)}, due, 7}), "changed SPS without explicit reset");
        check(frames == 3 && video_width == landscape_width, "SPS change replaces decoder session");
        const auto directory = std::filesystem::temp_directory_path() / ("airplay-player-test-" + std::to_string(getpid()));
        std::filesystem::create_directories(directory);
        const auto key = (directory / "pairing.pem").string();
        const uint8_t identity[] = {2,0,0,0,0,1};
        for (int session = 0; session < 3; ++session) {
            AirplayCallbacks callbacks{};
            auto *player = airplay_player_create(callbacks, nullptr, nullptr, nullptr);
            check(player, "create receiver with platform adapters");
            char error[512];
            check(airplay_player_start(player, "Synthetic Receiver", identity, key.c_str(), error, sizeof(error)), error);
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
            const char request[] = "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n";
            check(send(client, request, strlen(request), 0) == int(strlen(request)), "send synthetic RTSP request");
            char response[1024]{}; const auto received = recv(client, response, sizeof(response)-1, 0);
            check(received > 0 && strstr(response, "200 OK"), "receive real RTSP response"); close(client);
            airplay_player_destroy(player);
        }
        std::filesystem::remove_all(directory);
        std::puts("PASS: continuous audio clock, common timeline, PCM scheduling/gain/flush/late drop, Annex B, AAC/ALAC/AAC-ELD decode and FLUSH, FFmpeg RGBA pixels/rotation/keyframe recovery, receiver stop/restart/TXT/RTSP");
    } catch (const std::exception &e) { std::fprintf(stderr, "FAIL: %s\n", e.what()); return 1; }
}
