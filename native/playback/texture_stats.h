// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "timing_stats.h"
#include <cstddef>

namespace airplay {
// Caller owns synchronization. Acquisition is a Flutter texture read, not proof
// that a frame reached the display. Keep lifetime markers across report windows
// so a stalled producer or consumer remains visible when interval counts are zero.
struct TextureStats {
    uint64_t received = 0, acquired_new = 0, overwritten = 0, repeated = 0;
    uint64_t sequence = 0, acquired_sequence = 0;
    int64_t started_ns = 0, received_ns = 0, last_acquire_ns = 0;
    TimingSamples acquire_gap, frame_age, notify_delay;
    void receive(bool replaces_pending = true) {
        const auto now = TimingSamples::now_ns();
        if (!started_ns) started_ns = now;
        if (replaces_pending && sequence != acquired_sequence) ++overwritten;
        ++received; ++sequence; received_ns = now;
    }
    void acquire(uint64_t selected_sequence = 0, int64_t selected_received_ns = 0) {
        if (!sequence) return;
        const auto now = TimingSamples::now_ns();
        if (!selected_sequence) selected_sequence = sequence;
        if (selected_sequence > acquired_sequence) {
            ++acquired_new;
            if (last_acquire_ns) acquire_gap.add(now - last_acquire_ns);
            frame_age.add(now - (selected_received_ns ? selected_received_ns : received_ns));
            acquired_sequence = selected_sequence; last_acquire_ns = now;
        } else ++repeated;
    }
    void clear() { *this = {}; }
    std::string report(const char* backend, size_t width, size_t height) {
        if (!started_ns) return {};
        const auto now = TimingSamples::now_ns();
        char counts[512];
        std::snprintf(counts, sizeof(counts),
            "%s texture stats: interval_ms=%lld received=%llu acquired_new=%llu overwritten_before_acquire=%llu repeated_acquire=%llu pending=%d last_receive_age_ms=%.1f last_acquire_age_ms=%.1f size=%zux%zu",
            backend, static_cast<long long>((now - started_ns) / 1000000),
            static_cast<unsigned long long>(received), static_cast<unsigned long long>(acquired_new),
            static_cast<unsigned long long>(overwritten), static_cast<unsigned long long>(repeated),
            int(sequence != acquired_sequence), double(now - received_ns) / 1e6,
            last_acquire_ns ? double(now - last_acquire_ns) / 1e6 : -1, width, height);
        const auto result = std::string(counts) + acquire_gap.text("acquire_gap")
            + frame_age.text("frame_age") + notify_delay.text("notify_delay");
        received = acquired_new = overwritten = repeated = 0;
        acquire_gap = {}; frame_age = {}; notify_delay = {}; started_ns = now;
        return result;
    }
};
} // namespace airplay
