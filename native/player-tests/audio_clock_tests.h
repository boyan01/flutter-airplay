// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "audio_clock.h"
#include <stdexcept>

inline void check_audio_clock() {
    using namespace airplay;
    constexpr int total = kSampleRate, callback = 192;
    constexpr int64_t start = kSecond;
    AudioClock clock;
    AudioBuffer buffer;
    std::vector<int16_t> input(total * 2), output(total * 2);
    for (int i = 0; i < total; ++i)
        input[2 * i] = input[2 * i + 1] = int16_t(12000 * std::sin(2 * 3.141592653589793 * 440 * i / kSampleRate));
    buffer.write(input.data(), total, start, buffer.generation());
    for (int i = 0; i < total; i += callback) {
        const auto count = std::min(callback, total - i);
        // Reproduce the +/- 3 ms steps observed with Oboe's 44.1 -> 48 kHz filter.
        const int64_t jitter = i == 0 ? 0 : (i / callback) % 2 ? -3000000 : 3000000;
        const auto estimate = start + int64_t(i) * kSecond / kSampleRate + jitter;
        buffer.read(output.data() + i * 2, count, clock.next(count, estimate));
    }
    if (input != output) throw std::runtime_error("device callback jitter cuts continuous PCM");
    for (int i = 1; i < total; ++i)
        if (std::abs(int(output[2 * i]) - output[2 * (i - 1)]) > 1200)
            throw std::runtime_error("continuous tone has an audible discontinuity");
    clock.reset();
    if (clock.next(192, 5 * kSecond) != 5 * kSecond)
        throw std::runtime_error("audio device restart retains old clock");
    if (clock.next(192, 6 * kSecond) != 6 * kSecond)
        throw std::runtime_error("long device stall does not reanchor audio");
}

// WASAPI refills capacity - padding, so callback sizes vary with scheduling.
inline void check_audio_clock_variable_refills() {
    using namespace airplay;
    constexpr int total = 2 * kSampleRate;
    constexpr int64_t start = kSecond;
    std::vector<int16_t> input(total * 2), output(total * 2), unfiltered(total * 2);
    for (int i = 0; i < total; ++i) {
        input[2 * i] = int16_t(12000 * std::sin(2 * 3.141592653589793 * 440 * i / kSampleRate));
        input[2 * i + 1] = -input[2 * i];
    }
    AudioBuffer buffer, baseline;
    buffer.write(input.data(), total, start, buffer.generation());
    baseline.write(input.data(), total, start, baseline.generation());
    AudioClock clock;
    constexpr int sizes[] = {441, 256, 627, 384, 512};
    int callback = 0;
    for (int i = 0; i < total; ++callback) {
        const auto count = std::min(sizes[callback % 5], total - i);
        const int64_t jitter = callback == 0 ? 0 : callback % 2 ? 3000000 : -3000000;
        const auto estimate = start + int64_t(i) * kSecond / kSampleRate + jitter;
        buffer.read(output.data() + 2 * i, count, clock.next(count, estimate));
        baseline.read(unfiltered.data() + 2 * i, count, estimate);
        i += count;
    }
    if (input == unfiltered || !baseline.late_drops())
        throw std::runtime_error("fixture does not reproduce raw WASAPI estimate sample loss");
    if (input != output || buffer.late_drops())
        throw std::runtime_error("variable device refills cut or repeat stereo PCM");
    clock.reset(); // Generation change, endpoint drain or device replacement.
    buffer.flush();
    const int16_t resumed[] = {1234, -1234, 2345, -2345};
    int16_t actual[4]{};
    buffer.write(resumed, 2, 5 * kSecond, buffer.generation());
    buffer.read(actual, 2, clock.next(2, 5 * kSecond));
    if (!std::equal(std::begin(resumed), std::end(resumed), actual))
        throw std::runtime_error("restarted device does not play the new timeline");
}
