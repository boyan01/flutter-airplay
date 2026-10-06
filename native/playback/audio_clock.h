// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "timeline.h"

namespace airplay {
// Device estimates can repeat or jump while Oboe pulls resampler input blocks.
// The PCM callback needs the presentation time of its own next source frame.
class AudioClock {
public:
    int64_t next(size_t frames, int64_t estimate) {
        auto due = anchor_ + int64_t(frames_ / kSampleRate) * kSecond +
            int64_t(frames_ % kSampleRate) * kSecond / kSampleRate;
        // Small device timestamp and resampler steps are measurement jitter.
        // A real output interruption needs a new anchor rather than stale PCM.
        constexpr int64_t discontinuity = 20000000;
        if (!anchored_ || estimate < due - discontinuity || estimate > due + discontinuity) {
            anchor_ = due = estimate; frames_ = 0; anchored_ = true;
        }
        frames_ += frames;
        return due;
    }
    void reset() { anchored_ = false; frames_ = 0; }
private:
    bool anchored_ = false;
    int64_t anchor_ = 0;
    uint64_t frames_ = 0;
};
} // namespace airplay
