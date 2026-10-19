// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../../playback/video_recovery.h"
#include <stdexcept>
#include <vector>

namespace airplay_test {
inline void video_recovery_test() {
    using airplay::VideoRecovery;
    using Bytes = std::vector<uint8_t>;
    auto check = [](bool ok, const char *message) { if (!ok) throw std::runtime_error(message); };
    auto join = [](std::initializer_list<Bytes> parts) {
        Bytes result;
        for (const auto &part : parts) result.insert(result.end(), part.begin(), part.end());
        return result;
    };
    VideoRecovery recovery;
    // Returns the bytes handed to the decoder.
    auto decode = [&](Bytes bytes, bool accepted = true, bool hevc = false) {
        airplay::VideoPacket packet;
        packet.bytes = std::move(bytes); packet.hevc = hevc;
        recovery.prepare(packet);
        recovery.decoded(accepted);
        return packet.bytes;
    };
    const Bytes sps{0, 0, 0, 1, 0x67, 1, 2}, pps{0, 0, 0, 1, 0x68, 3};
    const Bytes sei{0, 0, 0, 1, 0x06, 9}, idr{0, 0, 0, 1, 0x65, 4, 5}, slice{0, 0, 0, 1, 0x41, 6};
    const auto key = join({sei, idr});

    check(decode(join({sps, pps})) == join({sps, pps}), "parameter sets pass through unchanged");
    check(decode(key) == key, "keyframes are unchanged before a failure");

    recovery.failed(10, 7);
    check(recovery.active(), "failure starts recovery");
    check(decode(slice) == slice, "non-keyframes are not given parameter sets");
    check(decode(key) == join({sps, pps, key}), "next keyframe replays the saved parameter sets");
    check(decode(key) == key, "parameter sets replay once per failure");

    // Parameter sets may arrive one per packet, with three-byte start codes.
    const Bytes sps2{0, 0, 0, 1, 0x67, 7}, pps2{0, 0, 0, 1, 0x68, 8};
    decode({0, 0, 1, 0x67, 7});
    decode({0, 0, 1, 0x68, 8});
    recovery.failed(15, 7);
    check(decode(key) == join({sps2, pps2, key}), "separately sent parameter sets are all replayed");

    recovery.failed(20, 7);
    check(decode(join({sps2, pps2, key})) == join({sps2, pps2, key}), "keyframes with all parameter sets are unchanged");
    recovery.failed(25, 7);
    check(decode(join({sps, key})) == join({sps, pps2, key}), "missing parameter sets are added in dependency order");

    // Parameter sets after an access unit delimiter are saved too.
    const Bytes aud{0, 0, 0, 1, 0x09, 0xf0};
    decode(join({aud, sps2, pps2}));
    recovery.failed(27, 7);
    check(decode(idr) == join({sps2, pps2, idr}), "parameter sets are found anywhere in a packet");

    // A rejected packet must not replace accepted parameter sets.
    decode(join({Bytes{0, 0, 0, 1, 0x67, 0xee}, idr}), false);
    recovery.failed(28, 7);
    check(decode(idr) == join({sps2, pps2, idr}), "rejected parameter sets are not saved");

    check(recovery.check(30, 7, false) == VideoRecovery::Result::waiting, "recovery waits for a picture");
    check(recovery.check(30, 8, false) == VideoRecovery::Result::recovered, "a new picture ends recovery");
    check(!recovery.active() && recovery.check(40, 8, false) == VideoRecovery::Result::idle, "recovery is idle after a picture");

    recovery.failed(50, 8);
    recovery.failed(60, 9);
    check(recovery.check(70, 9, false) == VideoRecovery::Result::waiting,
          "a failure after an unchecked picture starts a new window");
    recovery.clear();

    recovery.timeout = 100;
    recovery.failed(100, 8);
    check(recovery.check(150, 8, true) == VideoRecovery::Result::waiting, "paused sender waits");
    check(recovery.check(240, 8, false) == VideoRecovery::Result::waiting, "pause restarts the timeout");
    check(recovery.check(250, 8, false) == VideoRecovery::Result::timed_out, "no picture within the timeout fails");
    check(!recovery.active(), "timeout ends recovery");

    decode(join({sps, pps}));
    recovery.failed(300, 8);
    check(decode(idr, true, true) == idr, "parameter sets are not replayed into another codec");
    recovery.clear();
    recovery.failed(400, 8);
    check(decode(idr) == idr && recovery.active(), "a new stream has no saved parameter sets");
}
} // namespace airplay_test
