// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "platform.h"
#include "timeline.h"
#include <array>
#include <vector>

namespace airplay {
// Resumes decoding after a failed packet instead of ending the session.
// Senders send parameter sets only when a stream starts or changes format, and
// a decoder reset clears them, so keep the latest accepted ones and replay them
// with the next keyframe. Report a failure when no picture follows in time.
class VideoRecovery {
public:
    enum class Result { idle, waiting, recovered, timed_out };
    int64_t timeout = 5 * kSecond;

    // Call for each packet before decoding, then report the result to decoded().
    void prepare(VideoPacket &packet) {
        staged_ = {};
        staged_hevc_ = packet.hevc;
        std::vector<NalView> pictures;
        bool key = false;
        for (const auto &nal : split_nal_views(packet.bytes.data(), packet.bytes.size())) {
            if (!nal.size()) continue;
            const int type = packet.hevc ? (nal[0] >> 1) & 63 : nal[0] & 31;
            const int slot = packet.hevc ? (type >= 32 && type <= 34 ? type - 32 : -1)
                                         : type == 7 ? 1 : type == 8 ? 2 : -1;
            // Senders may send these together or one per packet; keep the latest of each.
            if (slot >= 0) staged_[slot] = annex_b(nal.data(), nal.size());
            else pictures.push_back(nal);
            key |= packet.hevc ? type >= 16 && type <= 23 : type == 5;
        }
        if (!replay_ || !key || packet.hevc != hevc_) return;
        // The reset decoder has no parameter sets. Rebuild the access unit with
        // every parameter set first, in VPS, SPS, PPS dependency order.
        std::vector<uint8_t> bytes;
        for (size_t slot = 0; slot < staged_.size(); ++slot) {
            const auto &parameter = staged_[slot].empty() ? parameters_[slot] : staged_[slot];
            bytes.insert(bytes.end(), parameter.begin(), parameter.end());
        }
        for (const auto &nal : pictures) {
            const auto unit = annex_b(nal.data(), nal.size());
            bytes.insert(bytes.end(), unit.begin(), unit.end());
        }
        packet.bytes = std::move(bytes);
        replay_ = false;
    }
    // Keep parameter sets only from packets the decoder accepted.
    void decoded(bool accepted) {
        if (!accepted) return;
        for (size_t slot = 0; slot < staged_.size(); ++slot) {
            if (staged_[slot].empty()) continue;
            if (staged_hevc_ != hevc_) { parameters_ = {}; hevc_ = staged_hevc_; }
            parameters_[slot] = std::move(staged_[slot]);
        }
        staged_ = {};
    }
    // The decoder was reset after rejecting a packet.
    void failed(int64_t now, int64_t last_output) {
        replay_ = true;
        // A picture since the previous failure starts a new recovery window.
        if (!since_ || last_output != output_) { since_ = now; output_ = last_output; }
    }
    bool active() const { return since_ != 0; }
    Result check(int64_t now, int64_t last_output, bool paused) {
        if (!since_) return Result::idle;
        if (last_output != output_) { since_ = 0; return Result::recovered; }
        // A sender pause sends no pictures; restart the window on resume.
        if (paused) { since_ = now; return Result::waiting; }
        if (now - since_ < timeout) return Result::waiting;
        since_ = 0;
        return Result::timed_out;
    }
    // A new stream must not reuse the previous stream's parameter sets.
    void clear() { parameters_ = {}; staged_ = {}; replay_ = false; since_ = 0; }

private:
    using ParameterSets = std::array<std::vector<uint8_t>, 3>; // VPS, SPS, PPS; H.264 has no VPS.
    static std::vector<uint8_t> annex_b(const uint8_t *data, size_t size) {
        std::vector<uint8_t> unit{0, 0, 0, 1};
        unit.insert(unit.end(), data, data + size);
        return unit;
    }

    ParameterSets parameters_, staged_;
    bool hevc_ = false, staged_hevc_ = false, replay_ = false;
    int64_t since_ = 0, output_ = 0;
};
} // namespace airplay
