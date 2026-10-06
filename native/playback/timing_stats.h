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
} // namespace airplay
