// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../../playback/audio_clock.h"
#include <stdexcept>

inline void check_audio_host_clock() {
    using namespace airplay;
    AudioBuffer buffer(441);
    const std::vector<int16_t> input(441 * 2, 12000);
    std::vector<int16_t> output(input.size());
    // The output stays open while the monotonic clock advances through sleep
    // and the device host clock does not. Preserve its scheduled 10 ms lead.
    for (const int64_t sleep : {int64_t(0), 60 * kSecond, 10 * 3600 * kSecond}) {
        const auto host_now = 100 * kSecond;
        const auto now = host_now + 10 * kSecond + sleep;
        const auto host_time = host_now + 10000000;
        const auto due = now + 10000000;
        if (buffer.write(input.data(), 441, due, buffer.generation()) != 441)
            throw std::runtime_error("sleep clock conversion leaves the PCM queue full");
        buffer.read(output.data(), 441, host_time_to_monotonic(host_now - 10000000, host_now, now));
        if (std::any_of(output.begin(), output.end(), [](auto x) { return x != 0; }))
            throw std::runtime_error("host clock conversion plays future PCM early");
        buffer.read(output.data(), 441, host_time_to_monotonic(host_time, host_now, now));
        if (input != output)
            throw std::runtime_error("sleep clock conversion silences or cuts scheduled PCM");
    }
}

inline void check_audio_queue_diagnostics() {
    using namespace airplay;
    AudioBuffer buffer(4);
    const int16_t silent[8]{};
    int16_t output[8]{};
    buffer.read(output, 2, kSecond); // No input, distinct from silent PCM.
    buffer.write(silent, 4, 2 * kSecond, buffer.generation());
    buffer.write(silent, 2, 2 * kSecond, buffer.generation()); // Full queue.
    buffer.read(output, 2, kSecond); // Input exists but is not due yet.
    buffer.read(output, 4, 2 * kSecond); // Decoded digital silence still plays.
    const auto report = buffer.diagnostics();
    for (const auto *field : {"queued_frames=0 ", "write_drop_total=2 ", "played_frames_total=4 ",
             "empty_silence_frames_total=2 ", "future_silence_frames_total=2 ", "late_drop_total=0 "}) {
        if (report.find(field) == std::string::npos)
            throw std::runtime_error("audio diagnostics cannot distinguish PCM overflow, starvation, future time and silent content: " + report);
    }
}

// Video packets every 1/60 s whose transit is `transit(i)`; returns the last arrival headroom.
template<class Transit> int64_t feed_video(airplay::Timeline &timeline, int64_t &pts, int64_t &now,
                                           int seconds, Transit transit) {
    int64_t headroom = 0, previous = 0;
    for (int i = 0; i < seconds * 60; ++i) {
        pts += airplay::kSecond / 60; now = pts + transit(i);
        const auto due = timeline.video(pts, now);
        // Adjustments are bounded steps, never a reversal of more than one step.
        if (previous && due - previous < airplay::kSecond / 60 - airplay::Timeline::kVideoMaxStepNs)
            throw std::runtime_error("timeline adjustment jumps video backwards");
        previous = due; headroom = due - now;
    }
    return headroom;
}

inline void check_timeline_adaptation() {
    using namespace airplay;
    const auto near = [](int64_t value, int64_t target) { return value >= target - 8000000 && value <= target + 8000000; };
    constexpr int64_t delay = 40000000, base = 10 * kSecond;
    Timeline timeline(delay);
    // A slow first packet (100 ms transit vs 40 ms) no longer holds every later frame.
    int64_t pts = 0, now = base + 100000000;
    if (timeline.video(pts, now) != now + delay) throw std::runtime_error("first video packet does not seed the buffer");
    pts = 0;
    if (!near(feed_video(timeline, pts, now, 20, [&](int) { return base + 40000000; }), delay))
        throw std::runtime_error("slow first packet keeps extra video delay");
    // Slower steady transit restores the configured headroom instead of presenting late.
    if (!near(feed_video(timeline, pts, now, 20, [&](int) { return base + 70000000; }), delay))
        throw std::runtime_error("slower transit leaves video late");
    // A repeated timestamp after an idle screen is not a transit sample.
    now += 30 * kSecond; timeline.video(pts - kSecond, now);
    if (!near(feed_video(timeline, pts, now, 4, [&](int) { return base + 70000000; }), delay))
        throw std::runtime_error("repeated idle timestamp moves the video clock");

    // Audio stays on the video clock while the device lead allows it.
    int64_t audio_pts = pts;
    const auto audio = [&](int64_t lead, int64_t read_lead, int packets) {
        int64_t due = 0;
        for (int i = 0; i < packets; ++i) {
            audio_pts += kSecond / 100;
            due = timeline.audio(audio_pts, read_lead, timeline.deadline(audio_pts) - lead);
        }
        return due - timeline.deadline(audio_pts);
    };
    if (audio(120000000, 20000000, 300) != 0) throw std::runtime_error("fast audio output leaves video sync");
    // A 140 ms device needs more lead than video sync gives; play late, never drop.
    const auto behind = audio(100000000, 140000000, 300);
    if (behind < 140000000 + Timeline::kAudioMarginNs - 100000000 || behind > 100000000)
        throw std::runtime_error("slow audio output is not delayed by its shortfall");
    if (audio(120000000, 20000000, 300) != 0) throw std::runtime_error("audio does not return to video sync");
    // An implausible device lead cannot push audio arbitrarily far behind the picture.
    if (audio(120000000, 2 * kSecond, 300) != Timeline::kAudioMaxBehindNs)
        throw std::runtime_error("audio delay behind video is unbounded");

    // Audio first, as on a session reset: the output lead still applies immediately.
    Timeline first(delay);
    const auto audio_due = first.audio(5 * kSecond, 140000000, base);
    if (audio_due - base < 140000000 + Timeline::kAudioMarginNs)
        throw std::runtime_error("audio-first anchor schedules PCM the device has already passed");
}

inline void check_audio_clock() {
    check_audio_host_clock();
    check_audio_queue_diagnostics();
    check_timeline_adaptation();
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
