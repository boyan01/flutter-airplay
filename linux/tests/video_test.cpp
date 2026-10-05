// SPDX-License-Identifier: GPL-3.0-only
// Synthetic platform-adapter regression; no display, audio device or sender.
#include "platform.h"
#include "linux_video.h"
#include "video_fixtures.h"
#include "resume_fixtures.h"
#include "hevc_fixtures.h"
#include "ffmpeg_colors_test.h"
#include "video_scheduler_test.h"
#include <thread>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>

using namespace airplay;
namespace {
void check(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

struct Frame {
    int width, height;
    int64_t deadline;
    uint64_t generation;
    std::array<std::array<uint8_t, 4>, 3> samples;
};

struct Probe {
    std::vector<Frame> frames;
    std::vector<std::string> logs;
    std::unique_ptr<VideoOutput> video = make_video_output(nullptr, nullptr, nullptr, {
        [this](void *pointer, int width, int height, int64_t deadline, uint64_t generation) {
            const auto *image = static_cast<const AirplayLinuxVideoFrame *>(pointer);
            check(image && image->data, "callback borrows a populated RGBA frame");
            check(image->width == width && image->height == height && width > 0 && height > 0,
                  "callback and frame dimensions agree");
            check(image->stride >= width * 4, "RGBA stride covers every pixel");
            Frame frame{width, height, deadline, generation, {}};
            const std::array<std::pair<int, int>, 3> points{{{0, 0}, {width / 2, height / 2}, {width - 1, height - 1}}};
            for (size_t i = 0; i < points.size(); ++i) {
                const auto *pixel = image->data + size_t(points[i].second) * image->stride + points[i].first * 4;
                // Copy in the callback: neither pointer may be retained by a host.
                std::copy_n(pixel, 4, frame.samples[i].begin());
            }
            frames.push_back(frame);
        }, [this](const char *message) { logs.emplace_back(message); }
    });
    bool decode(const VideoPacket &packet) {
        if (!video->decode(packet)) return false;
        const auto until = monotonic_ns() + 3 * kSecond;
        do {
            video->drain();
            if (!video->next_deadline()) return true;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        } while (monotonic_ns() < until);
        throw std::runtime_error("Timed out presenting decoded fixture");
    }
};

std::vector<uint8_t> read_file(const std::filesystem::path &path) {
    std::ifstream input(path, std::ios::binary);
    check(bool(input), "open generated video fixture (run generate_video_fixtures.sh first)");
    std::vector<uint8_t> bytes{std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
    check(!bytes.empty() && bytes.size() <= 4 * 1024 * 1024, "generated fixture size is bounded");
    return bytes;
}

void append_nal(std::vector<uint8_t> &packet, const std::vector<uint8_t> &nal, bool short_prefix) {
    if (!short_prefix) packet.push_back(0);
    packet.insert(packet.end(), {0, 0, 1});
    packet.insert(packet.end(), nal.begin(), nal.end());
}

struct SplitFrame {
    std::vector<std::vector<uint8_t>> parameters;
    std::vector<uint8_t> picture;
};

template <size_t N> SplitFrame split_frame(const uint8_t (&input)[N], bool hevc = false) {
    SplitFrame split;
    bool short_prefix = false;
    for (const auto &nal : split_nals(input, N)) {
        std::vector<uint8_t> bytes;
        append_nal(bytes, nal, short_prefix = !short_prefix);
        const auto type = hevc ? (nal[0] >> 1) & 63 : nal[0] & 31;
        if (hevc ? type >= 32 && type <= 34 : type == 7 || type == 8) split.parameters.push_back(std::move(bytes));
        else split.picture.insert(split.picture.end(), bytes.begin(), bytes.end());
    }
    check(split.parameters.size() == (hevc ? 3 : 2) && !split.picture.empty(), "fixture has separate parameter sets and picture");
    return split;
}

void send_parameters(Probe &probe, const SplitFrame &split, bool hevc = false) {
    const auto before = probe.frames.size();
    for (const auto &parameter : split.parameters) {
        check(probe.decode({parameter, -123, 999, 0, hevc}), "accept parameter-only packet");
        probe.video->drain();
    }
    check(probe.frames.size() == before, "configuration packets do not publish pictures");
}

void check_red(const Frame &frame, int width, int height, int64_t deadline, uint64_t generation) {
    check(frame.width == width && frame.height == height, "actual source dimensions survive rotation");
    check(frame.deadline == deadline && frame.generation == generation, "exact nanosecond deadline and 64-bit generation");
    for (const auto &pixel : frame.samples)
        check(pixel[0] > 200 && pixel[1] < 30 && pixel[2] < 30 && pixel[3] == 255, "RGBA pixels are opaque red");
}

void check_configuration_rotation_and_reset() {
    Probe probe;
    const auto wide = split_frame(landscape), tall = split_frame(portrait);
    const int64_t deadline = monotonic_ns() + kSecond;
    constexpr uint64_t generation = UINT64_C(0xFEDCBA9876543210);
    probe.video->size(111, 222);
    send_parameters(probe, wide);
    send_parameters(probe, wide); // A repeated configuration must remain bounded.
    check(probe.decode({wide.picture, deadline, generation}), "decode independent headers and IDR");
    check(probe.frames.size() == 1, "first IDR publishes once");
    check_red(probe.frames.back(), landscape_width, landscape_height, deadline, generation);
    for (int i = 0; i < 10; ++i) probe.video->drain();
    check(probe.frames.size() == 1, "ordinary drain neither finalizes nor duplicates output");

    send_parameters(probe, tall);
    check(probe.decode({tall.picture, deadline + 7, generation + 1}), "decode portrait without reset");
    check(probe.frames.size() == 2, "portrait frame publishes once");
    check_red(probe.frames.back(), landscape_height, landscape_width, deadline + 7, generation + 1);
    // Reusing a deadline must not reuse the preceding frame's generation.
    check(probe.decode({{std::begin(landscape), std::end(landscape)}, deadline + 7, generation + 2}),
          "decode landscape with repeated timestamp");
    check(probe.frames.size() == 3, "landscape resumes after orientation change");
    check_red(probe.frames.back(), landscape_width, landscape_height, deadline + 7, generation + 2);

    probe.video->reset();
    send_parameters(probe, wide);
    send_parameters(probe, tall);
    send_parameters(probe, wide);
    check(probe.decode({wide.picture, deadline + 9, generation + 3}), "A-B-A parameter updates preserve final order");
    check_red(probe.frames.back(), landscape_width, landscape_height, deadline + 9, generation + 3);

    probe.video->reset();
    const auto before = probe.frames.size();
    check(probe.decode({{std::begin(resume_frame_1), std::end(resume_frame_1)}, deadline, generation}),
          "after reset, skip inter frames until an IDR");
    probe.video->drain();
    check(probe.frames.size() == before, "reset and skipped inter frame publish no stale picture");
    const auto logs = probe.logs.size();
    check(!probe.decode({wide.picture, deadline, generation}), "reset also discards the old SPS/PPS");
    check(probe.logs.size() > logs, "missing post-reset configuration is logged");
    probe.video->reset();
    send_parameters(probe, tall);
    check(probe.decode({tall.picture, deadline + 11, generation + 4}), "recover with fresh post-reset configuration");
    check(probe.frames.size() == before + 1, "fresh generation publishes exactly one frame");
    check_red(probe.frames.back(), landscape_height, landscape_width, deadline + 11, generation + 4);
}

void check_deferred_output() {
    Probe probe;
    const auto due = monotonic_ns() + kSecond;
    for (int i = 0; i < 3; ++i)
        check(probe.video->decode({{std::begin(landscape), std::end(landscape)}, due + i * 16666667, 12}),
              "Decode future pictures without presentation waits");
    check(monotonic_ns() < due && probe.frames.empty(), "Future pictures return promptly and remain held");
    check(!probe.video->can_decode() && probe.video->next_deadline() == due - 2000000,
          "Completed pictures provide input backpressure and an exact wakeup");
    probe.video->drain();
    check(probe.frames.empty(), "Ordinary drain retains future output");
    probe.video->reset(); probe.video->drain();
    check(probe.frames.empty() && probe.video->can_decode() && !probe.video->next_deadline(),
          "Reset returns held RGBA pictures without publishing old output");
    const auto next_due = monotonic_ns() + kSecond;
    check(probe.decode({{std::begin(landscape), std::end(landscape)}, next_due, 13}), "Resume after held-picture reset");
    check(probe.frames.size() == 1 && probe.frames.back().generation == 13, "Only the new session is displayed");
}

void check_malformed_and_bounds(const std::filesystem::path &directory) {
    Probe probe;
    const std::vector<std::vector<uint8_t>> malformed{
        {}, {0, 0, 0, 0}, {0x65, 0x01}, {0, 0, 1}, {0, 0, 1, 0xFF},
        {0, 0, 1, 0x67}, {0, 0, 1, 0x65, 0x01},
        std::vector<uint8_t>(4 * 1024 * 1024 + 1), read_file(directory / "oversized.h264")
    };
    for (const auto &packet : malformed) {
        probe.video->reset();
        const auto logs = probe.logs.size();
        check(!probe.decode({packet, 1, 2}), "reject malformed or out-of-bounds video");
        check(probe.logs.size() > logs, "decoder failure reaches the application log");
        probe.video->drain();
        check(probe.frames.empty(), "invalid inputs never reach the frame callback");
    }
    probe.video->reset();
    const auto recovered_due = monotonic_ns() + kSecond;
    check(probe.decode({{std::begin(landscape), std::end(landscape)}, recovered_due, 17}),
          "decoder recovers after malformed and oversized input");
    check(probe.frames.size() == 1, "recovered decoder publishes exactly one frame");
    check_red(probe.frames.back(), landscape_width, landscape_height, recovered_due, 17);
}

void check_b_frame_metadata(const std::filesystem::path &directory) {
    const auto bytes = read_file(directory / "reorder.h264");
    std::ifstream manifest(directory / "reorder.tsv");
    check(bool(manifest), "open B-frame packet manifest");
    struct Packet { size_t offset, size; int index; char type; };
    std::vector<Packet> packets;
    std::set<int> indices;
    std::string line;
    size_t end = 0;
    bool contains_b = false, reordered = false;
    while (std::getline(manifest, line)) {
        std::istringstream row(line);
        Packet packet{};
        check(bool(row >> packet.offset >> packet.size >> packet.index >> packet.type), "parse B-frame packet metadata");
        row >> std::ws;
        check(row.eof() && packet.offset == end && packet.size > 0 && packet.offset < bytes.size()
              && packet.size <= bytes.size() - packet.offset, "manifest covers contiguous bounded packets");
        check(packet.index >= 0 && packet.index < 18 && indices.insert(packet.index).second,
              "presentation indices uniquely cover the generated sequence");
        contains_b |= packet.type == 'B';
        reordered |= packet.index != int(packets.size());
        end = packet.offset + packet.size;
        packets.push_back(packet);
    }
    check(packets.size() == 18 && end == bytes.size() && contains_b && reordered, "fixture really contains reordered B frames");

    Probe probe;
    const int64_t anchor = monotonic_ns() + kSecond;
    constexpr int64_t tick = 33333333;
    std::map<int64_t, std::pair<uint64_t, int>> expected;
    bool delayed_pts = false;
    int last_index = -1;
    for (size_t i = 0; i < packets.size(); ++i) {
        const auto &packet = packets[i];
        const int64_t deadline = anchor + packet.index * tick;
        const uint64_t generation = UINT64_C(1) << 48;
        expected.emplace(deadline, std::make_pair(generation, packet.index));
        const auto before = probe.frames.size();
        check(probe.decode({{bytes.begin() + packet.offset, bytes.begin() + packet.offset + packet.size}, deadline, generation}),
              "decode B-frame access unit");
        probe.video->drain();
        for (size_t j = before; j < probe.frames.size(); ++j) {
            const auto &frame = probe.frames[j];
            const auto match = expected.find(frame.deadline);
            check(match != expected.end() && match->second.first == frame.generation,
                  "reordering retains each originating packet's exact deadline and generation");
            const int index = match->second.second;
            check(index == last_index + 1, "decoded pictures arrive in presentation order");
            last_index = index;
            delayed_pts |= frame.deadline != deadline;
            check(frame.width == 160 && frame.height == 96, "B-frame dimensions");
            const int gray = (16 + index * 4) * 255 / 219;
            for (const auto &pixel : frame.samples) {
                check(std::abs(int(pixel[0]) - gray) <= 3 && std::abs(int(pixel[1]) - gray) <= 3
                      && std::abs(int(pixel[2]) - gray) <= 3 && pixel[3] == 255,
                      "picture pixels match the frame identified by its deadline");
            }
        }
    }
    check(probe.frames.size() >= 16 && probe.frames.size() < 18 && delayed_pts,
          "real delayed output exercises packet association rather than latest-packet metadata");
    const auto before = probe.frames.size();
    for (int i = 0; i < 10; ++i) probe.video->drain();
    check(probe.frames.size() == before, "idle drain does not send EOS and release reorder-delayed frames");
    probe.video->reset();
    probe.video->drain();
    check(probe.frames.size() == before, "reset discards reorder-delayed frames without callbacks");
    const auto recovered_due = monotonic_ns() + kSecond;
    check(probe.decode({{std::begin(portrait), std::end(portrait)}, recovered_due, 31}),
          "fresh stream opens after reset of delayed B frames");
    check(probe.frames.size() == before + 1, "new stream contains no old delayed output");
    check_red(probe.frames.back(), landscape_height, landscape_width, recovered_due, 31);
}
} // namespace

void check_hevc() {
    Probe probe;
    check(probe.video->supports_hevc(), "FFmpeg HEVC decoding is advertised when available");
    const auto feed = [&](const uint8_t *data, size_t size, int width, int height, int channel) {
        const auto before = probe.frames.size();
        const auto due = monotonic_ns() + kSecond;
        check(probe.decode({{data, data + size}, due, 77, 0, true}), "HEVC access unit accepted");
        probe.video->drain();
        check(probe.frames.size() == before + 1, "HEVC publishes one frame");
        const auto &frame = probe.frames.back();
        check(frame.width == width && frame.height == height, "HEVC actual dimensions match the source");
        check(frame.deadline == due && frame.generation == 77, "HEVC retains packet timing and generation");
        for (const auto &pixel : frame.samples)
            check(pixel[channel] > 200 && pixel[(channel + 1) % 3] < 45 &&
                  pixel[(channel + 2) % 3] < 45 && pixel[3] == 255, "HEVC decoded RGBA color");
    };
    feed(hevc_fixtures::landscape, sizeof(hevc_fixtures::landscape), 640, 360, 0);
    feed(hevc_fixtures::portrait, sizeof(hevc_fixtures::portrait), 360, 640, 2);
    probe.video->reset();
    const auto wide = split_frame(hevc_fixtures::landscape, true);
    send_parameters(probe, wide, true);
    const auto split_due = monotonic_ns() + kSecond;
    check(probe.decode({wide.picture, split_due, 78, 0, true}), "HEVC split VPS/SPS/PPS and IRAP decode");
    check_red(probe.frames.back(), 640, 360, split_due, 78);
    const auto before = probe.frames.size();
    check(!probe.decode({{0, 0, 1, 0x40}, 101, 78, 0, true}), "truncated HEVC NAL is rejected");
    probe.video->drain();
    check(probe.frames.size() == before, "malformed HEVC publishes no stale image");
    probe.video->reset();
    feed(hevc_fixtures::portrait, sizeof(hevc_fixtures::portrait), 360, 640, 2);
    feed(hevc_fixtures::uhd, sizeof(hevc_fixtures::uhd), 3840, 2160, 2);
    feed(hevc_fixtures::main10, sizeof(hevc_fixtures::main10), 640, 360, 1);
    const auto avc_due = monotonic_ns() + kSecond;
    check(probe.decode({{std::begin(landscape), std::end(landscape)}, avc_due, 78}), "HEVC switches back to H.264");
    check_red(probe.frames.back(), 640, 360, avc_due, 78);
}

int main(int argc, char **argv) {
    try {
        check(argc == 2, "Usage: linux_video_tests <generated-fixture-directory>");
        airplay_test::video_scheduler_test();
        airplay_test::ffmpeg_colors_test();
        check_hevc();
        check_configuration_rotation_and_reset();
        check_deferred_output();
        check_malformed_and_bounds(argv[1]);
        check_b_frame_metadata(argv[1]);
        std::puts("PASS: FFmpeg HEVC/H.264 RGBA pixels, landscape/portrait/4K/Main10, codec switch, split parameters, exact timing/generation, malformed/bounded input, reset and B-frame reordering");
    } catch (const std::exception &error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        return 1;
    }
}
