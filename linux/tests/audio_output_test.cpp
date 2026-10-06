// SPDX-License-Identifier: GPL-3.0-only
#include "../../native/playback/platform.h"
#include "../../native/playback/audio_clock.h"
#include <cstdio>
#include <cstdlib>
#include <stdexcept>

int main() {
    try {
        // A missing server must be a clean failure, including repeated attempts.
        setenv("PULSE_SERVER", "unix:/nonexistent-airplay-regression", 1);
        for (int i = 0; i < 5; ++i) {
            auto output = airplay::make_audio_output(std::make_shared<airplay::AudioBuffer>());
            if (output->start()) throw std::runtime_error("missing Pulse server reported success");
            output->stop(); output->stop();
        }
        // A large device refill without timing data still has distinct chunk
        // deadlines; reusing a fixed estimate would rewind the clock at 20ms.
        airplay::AudioClock clock;
        constexpr int64_t estimate = 1000000000;
        size_t written = 0;
        for (int i = 0; i < 4; ++i) {
            const auto expected = estimate + int64_t(written) * airplay::kSecond / airplay::kSampleRate;
            if (clock.next(2048, expected) != expected)
                throw std::runtime_error("large refill repeats its presentation deadline");
            written += 2048;
        }
        std::puts("PASS: unavailable Pulse server cleanup, repeated start/stop, continuous large refill timing");
    } catch (const std::exception &error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1;
    }
}
