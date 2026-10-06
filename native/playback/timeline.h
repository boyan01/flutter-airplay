// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <ctime>
#ifdef _WIN32
#include <chrono>
#endif
#include <mutex>
#include <vector>

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

// One session anchor for both media streams, including packets arriving audio-first.
class Timeline {
public:
    explicit Timeline(int64_t delay = 80000000) : delay_(delay) {}
    int64_t deadline(int64_t local_pts, int64_t now = monotonic_ns()) {
        std::lock_guard<std::mutex> guard(lock_);
        if (!anchored_) { offset_ = now + delay_ - local_pts; anchored_ = true; }
        return local_pts + offset_;
    }
    void reset() { std::lock_guard<std::mutex> guard(lock_); anchored_ = false; }
private:
    std::mutex lock_;
    const int64_t delay_;
    bool anchored_ = false;
    int64_t offset_ = 0;
};

// Bounded SPSC PCM queue. Only the decoder writes; one output callback or writer reads.
// Per-frame deadlines preserve silence, clock changes and device output latency.
// FLUSH invalidates old frames by generation without racing either ring index.
#ifdef _MSC_VER
#pragma warning(push)
// The queue indices deliberately occupy separate cache lines.
#pragma warning(disable: 4324)
#endif
class AudioBuffer {
public:
    explicit AudioBuffer(size_t capacity = 131072) : frames_(capacity), capacity_(capacity) {}
    uint64_t generation() const { return generation_.load(std::memory_order_acquire); }
    uint64_t late_drops() const { return late_drops_.load(std::memory_order_relaxed); }
    uint64_t stale_drops() const { return stale_drops_.load(std::memory_order_relaxed); }
    float gain() const { return gain_.load(std::memory_order_relaxed); }
    void flush() { generation_.fetch_add(1, std::memory_order_acq_rel); }
    void volume(float db) {
        gain_.store(db <= -144 ? 0.f : std::pow(10.f, std::clamp(db, -30.f, 0.f) / 20.f));
    }
    size_t write(const int16_t *pcm, size_t count, int64_t deadline, uint64_t generation) {
        const auto read = read_.load(std::memory_order_acquire);
        auto write = write_.load(std::memory_order_relaxed);
        size_t copied = std::min(count, capacity_ - size_t(write - read));
        for (size_t i = 0; i < copied; ++i) {
            auto &frame = frames_[(write + i) % capacity_];
            frame = {pcm[i * 2], pcm[i * 2 + 1], deadline + int64_t(i) * kSecond / kSampleRate, generation};
        }
        write_.store(write + copied, std::memory_order_release);
        return copied;
    }
    void read(int16_t *pcm, size_t count, int64_t output_time) {
        auto read = read_.load(std::memory_order_relaxed);
        const auto write = write_.load(std::memory_order_acquire);
        const auto generation = this->generation();
        const float gain = gain_.load(std::memory_order_relaxed);
        uint64_t late = 0, stale = 0;
        for (size_t i = 0; i < count; ++i) {
            pcm[i * 2] = pcm[i * 2 + 1] = 0;
            const auto due = output_time + int64_t(i) * kSecond / kSampleRate;
            while (read < write) {
                const auto &frame = frames_[read % capacity_];
                if (frame.generation != generation) { ++stale; ++read; continue; }
                if (frame.deadline < due - 2000000) { ++late; ++read; continue; }
                if (frame.deadline > due + kSecond / kSampleRate) break;
                pcm[i * 2] = int16_t(frame.left * gain);
                pcm[i * 2 + 1] = int16_t(frame.right * gain);
                ++read;
                break;
            }
        }
        read_.store(read, std::memory_order_release);
        late_drops_.fetch_add(late, std::memory_order_relaxed);
        stale_drops_.fetch_add(stale, std::memory_order_relaxed);
    }
private:
    struct Frame { int16_t left, right; int64_t deadline; uint64_t generation; };
    std::vector<Frame> frames_;
    const size_t capacity_;
    alignas(64) std::atomic<uint64_t> read_{0}, write_{0};
    std::atomic<uint64_t> generation_{1};
    std::atomic<float> gain_{1};
    std::atomic<uint64_t> late_drops_{0}, stale_drops_{0};
};
#ifdef _MSC_VER
#pragma warning(pop)
#endif
} // namespace airplay
