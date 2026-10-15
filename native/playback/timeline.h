// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <ctime>
#include <cstdio>
#include <string>
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

// Translate a device's host timestamp using adjacent samples of both clocks.
// A cached epoch difference is invalid after sleep if only one clock advances.
inline int64_t host_time_to_monotonic(int64_t host_time, int64_t host_now, int64_t now) {
    return now + (host_time - host_now);
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
    void set_delay(int64_t delay) {
        std::lock_guard<std::mutex> guard(lock_); delay_ = delay; anchored_ = false;
    }
    void reset() { std::lock_guard<std::mutex> guard(lock_); anchored_ = false; }
    std::string diagnostics() {
        std::lock_guard<std::mutex> guard(lock_);
        char text[160];
        std::snprintf(text, sizeof(text), "timeline_anchored=%d timeline_delay_ms=%.1f timeline_offset_ms=%.1f",
            int(anchored_), delay_ / 1e6, anchored_ ? offset_ / 1e6 : 0);
        return text;
    }
private:
    std::mutex lock_;
    int64_t delay_;
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
    float volume_db() const { return volume_db_.load(std::memory_order_relaxed); }
    float gain() const {
        const auto db = volume_db();
        return db <= -144 ? 0.f : std::pow(10.f, db / 20.f);
    }
    std::string diagnostics() const {
        // Never inspect ring frames from the reporting thread: only the SPSC
        // reader/writer owns them. Atomic snapshots are approximate but bounded.
        const auto read = read_.load(std::memory_order_acquire);
        const auto write = write_.load(std::memory_order_acquire);
        const auto queued = std::min<uint64_t>(write - read, capacity_);
        const auto now = monotonic_ns(), written = last_write_.load(), pulled = last_pull_.load();
        char text[768];
        std::snprintf(text, sizeof(text),
            "PCM queue: generation=%llu queued_frames=%llu queued_ms=%.1f capacity=%zu write_drop_total=%llu played_frames_total=%llu empty_silence_frames_total=%llu future_silence_frames_total=%llu late_drop_total=%llu stale_drop_total=%llu last_future_lead_ms=%.1f output_time_lead_ms=%.1f last_write_age_ms=%.1f last_pull_age_ms=%.1f gain=%.3f",
            static_cast<unsigned long long>(generation()), static_cast<unsigned long long>(queued),
            double(queued) * 1000 / kSampleRate, capacity_,
            static_cast<unsigned long long>(write_drops_.load()), static_cast<unsigned long long>(played_.load()),
            static_cast<unsigned long long>(empty_.load()), static_cast<unsigned long long>(future_.load()),
            static_cast<unsigned long long>(late_drops()), static_cast<unsigned long long>(stale_drops()),
            future_lead_.load() / 1e6, output_lead_.load() / 1e6,
            written ? (now - written) / 1e6 : -1, pulled ? (now - pulled) / 1e6 : -1, gain());
        return text;
    }
    void flush() { generation_.fetch_add(1, std::memory_order_acq_rel); }
    void volume(float db) {
        volume_db_.store(db <= -144 ? -144.f : std::clamp(db, -30.f, 0.f));
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
        write_drops_.fetch_add(count - copied, std::memory_order_relaxed);
        last_write_.store(monotonic_ns(), std::memory_order_relaxed);
        return copied;
    }
    void read(int16_t *pcm, size_t count, int64_t output_time) {
        auto read = read_.load(std::memory_order_relaxed);
        const auto write = write_.load(std::memory_order_acquire);
        const auto generation = this->generation();
        const float gain = this->gain();
        uint64_t late = 0, stale = 0, played = 0, future = 0;
        int64_t future_lead = 0;
        for (size_t i = 0; i < count; ++i) {
            pcm[i * 2] = pcm[i * 2 + 1] = 0;
            const auto due = output_time + int64_t(i) * kSecond / kSampleRate;
            while (read < write) {
                const auto &frame = frames_[read % capacity_];
                if (frame.generation != generation) { ++stale; ++read; continue; }
                if (frame.deadline < due - 2000000) { ++late; ++read; continue; }
                if (frame.deadline > due + kSecond / kSampleRate) {
                    ++future; future_lead = frame.deadline - due; break;
                }
                pcm[i * 2] = int16_t(frame.left * gain);
                pcm[i * 2 + 1] = int16_t(frame.right * gain);
                ++read;
                ++played;
                break;
            }
        }
        read_.store(read, std::memory_order_release);
        late_drops_.fetch_add(late, std::memory_order_relaxed);
        stale_drops_.fetch_add(stale, std::memory_order_relaxed);
        played_.fetch_add(played, std::memory_order_relaxed);
        future_.fetch_add(future, std::memory_order_relaxed);
        empty_.fetch_add(count - played - future, std::memory_order_relaxed);
        if (future) future_lead_.store(future_lead, std::memory_order_relaxed);
        const auto now = monotonic_ns();
        output_lead_.store(output_time - now, std::memory_order_relaxed);
        last_pull_.store(now, std::memory_order_relaxed);
    }
private:
    struct Frame { int16_t left, right; int64_t deadline; uint64_t generation; };
    std::vector<Frame> frames_;
    const size_t capacity_;
    alignas(64) std::atomic<uint64_t> read_{0}, write_{0};
    std::atomic<uint64_t> generation_{1};
    std::atomic<float> volume_db_{0};
    std::atomic<uint64_t> late_drops_{0}, stale_drops_{0};
    std::atomic<uint64_t> write_drops_{0}, played_{0}, empty_{0}, future_{0};
    std::atomic<int64_t> last_write_{0}, last_pull_{0}, future_lead_{0}, output_lead_{0};
};
#ifdef _MSC_VER
#pragma warning(pop)
#endif
} // namespace airplay
