// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "timeline.h"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <string>

namespace airplay {
// Caller owns synchronization. Peaks carry wall time to correlate pipeline logs;
// durations always use the monotonic clock. Reset these samples each report.
struct TimingSamples {
    static int64_t now_ns() {
        // Scheduler deadlines and durations must share the receive clock.
        // On macOS, steady_clock and CLOCK_MONOTONIC differ after system sleep.
        return monotonic_ns();
    }
    uint64_t count = 0, over_16ms = 0, over_33ms = 0;
    int64_t total_ns = 0, max_ns = 0, peak_utc_ms = 0;
    void add(int64_t ns) {
        ns = std::max<int64_t>(0, ns);
        ++count; total_ns += ns;
        over_16ms += ns > 1000000000 / 60;
        over_33ms += ns > 1000000000 / 30;
        if (ns > max_ns) {
            max_ns = ns;
            peak_utc_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
        }
    }
    std::string text(const char *name) const {
        char output[320];
        std::snprintf(output, sizeof(output),
            " %s_avg_ms=%.3f %s_max_ms=%.3f %s_over_16ms=%llu %s_over_33ms=%llu %s_peak_utc_ms=%lld",
            name, count ? double(total_ns) / count / 1000000 : 0,
            name, double(max_ns) / 1000000, name, static_cast<unsigned long long>(over_16ms),
            name, static_cast<unsigned long long>(over_33ms), name, static_cast<long long>(peak_utc_ms));
        return output;
    }
};

// Deadline minus observation time: positive is buffer headroom, negative is
// lateness. Keep the sign; duration samples intentionally clamp negatives.
struct DeadlineSamples {
    uint64_t count = 0;
    int64_t total_ns = 0, min_ns = 0, max_ns = 0;
    void add(int64_t ns) {
        if (!count) min_ns = max_ns = ns;
        else { min_ns = std::min(min_ns, ns); max_ns = std::max(max_ns, ns); }
        ++count; total_ns += ns;
    }
    std::string text(const char *name) const {
        char output[256];
        std::snprintf(output, sizeof(output), " %s_samples=%llu %s_avg_ms=%.3f %s_min_ms=%.3f %s_max_ms=%.3f",
            name, static_cast<unsigned long long>(count), name, count ? double(total_ns) / count / 1e6 : 0,
            name, min_ns / 1e6, name, max_ns / 1e6);
        return output;
    }
};

// Render notifications may arrive late and in batches. Derive pacing from the
// carried system timestamp, and measure delivery delay separately.
struct RenderTimingSamples {
    uint64_t callbacks = 0, nonpositive_steps = 0;
    int64_t last_render_ns = 0;
    TimingSamples gap, callback_delay;
    DeadlineSamples slack;
    void add(int64_t deadline_ns, int64_t rendered_ns, int64_t notified_ns) {
        ++callbacks;
        slack.add(deadline_ns - rendered_ns);
        callback_delay.add(notified_ns - rendered_ns);
        if (last_render_ns) {
            if (rendered_ns > last_render_ns) gap.add(rendered_ns - last_render_ns);
            else ++nonpositive_steps;
        }
        last_render_ns = std::max(last_render_ns, rendered_ns);
    }
    std::string text() const {
        char counts[160];
        std::snprintf(counts, sizeof(counts), " rendered_callbacks=%llu render_nonpositive_steps=%llu",
            static_cast<unsigned long long>(callbacks), static_cast<unsigned long long>(nonpositive_steps));
        return std::string(counts) + slack.text("render_slack") + gap.text("render_gap")
            + callback_delay.text("render_callback_delay");
    }
};
} // namespace airplay
