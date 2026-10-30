// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
#include <ctime>
#ifdef _WIN32
#include <chrono>
#endif

// Clocks shared by the player and the hosts' display statistics. lychee owns
// the media timeline; these only convert UxPlay's times and frame deadlines.
namespace airplay {
constexpr int kSampleRate = 44100;
constexpr int64_t kSecond = 1000000000;
inline int64_t monotonic_ns() {
#ifdef _WIN32
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
#else
    timespec ts{}; clock_gettime(CLOCK_MONOTONIC, &ts);
    return int64_t(ts.tv_sec) * kSecond + ts.tv_nsec;
#endif
}
inline int64_t realtime_ns() {
#ifdef _WIN32
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
#else
    timespec ts{}; clock_gettime(CLOCK_REALTIME, &ts);
    return int64_t(ts.tv_sec) * kSecond + ts.tv_nsec;
#endif
}
}  // namespace airplay
