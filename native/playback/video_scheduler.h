// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "timing_stats.h"
#include <algorithm>
#include <functional>
#include <mutex>
#include <vector>

namespace airplay {
constexpr int64_t kVideoLateToleranceNs = 150000000;
// Completed pictures only; compressed reference pictures must still be decoded.
// finish(true) submits a native lease, finish(false) discards it. Both return
// ownership, including on reset and destruction. Host calls borrow that lease.
class VideoScheduler {
public:
    struct Stats { uint64_t submitted = 0, dropped = 0; size_t pending = 0; };
    Stats stats() const {
        std::lock_guard<std::mutex> guard(lock_);
        return {total_submitted_, total_dropped_, frames_.size()};
    }
    // Lead controls early handoff. Timed hosts retain the original deadline;
    // texture hosts use a short lead for the engine to acquire the frame.
    explicit VideoScheduler(int64_t lead_ns = 2000000, size_t decode_ahead = 3)
        : lead_ns_(lead_ns), decode_ahead_(decode_ahead) {}
    ~VideoScheduler() { clear(); }
    VideoScheduler(const VideoScheduler &) = delete;
    VideoScheduler &operator=(const VideoScheduler &) = delete;
    void begin(uint64_t generation) {
        std::lock_guard<std::mutex> guard(lock_);
        if (generation_ != generation) { clear_locked(); generation_ = generation; }
    }
    void enqueue(int64_t due, uint64_t generation, std::function<void(bool)> finish) {
        std::lock_guard<std::mutex> guard(lock_);
        if (generation != generation_) { finish(false); ++cancelled_; return; }
        frames_.push_back({due, std::move(finish)});
        ++ready_; peak_ = std::max(peak_, frames_.size());
        // A codec drain can yield a burst beyond the input watermark. Keep the
        // nearest deadlines and bound retained 4K/GPU resources even then.
        if (frames_.size() > 16) {
            auto last = std::max_element(frames_.begin(), frames_.end(), earlier);
            last->finish(false); frames_.erase(last); ++overflow_; ++total_dropped_;
        }
    }
    bool can_decode() const {
        std::lock_guard<std::mutex> guard(lock_);
        return frames_.size() < decode_ahead_;
    }
    int64_t next_deadline() const {
        std::lock_guard<std::mutex> guard(lock_);
        return frames_.empty() ? 0 : std::min_element(frames_.begin(), frames_.end(), earlier)->due - lead_ns_;
    }
    void drain(int64_t clock_ns = 0) {
        for (;;) {
            const auto now = clock_ns ? clock_ns : TimingSamples::now_ns();
            Frame frame;
            bool show;
            {
                std::lock_guard<std::mutex> guard(lock_);
                if (frames_.empty()) break;
                auto first = std::min_element(frames_.begin(), frames_.end(), earlier);
                if (first->due - lead_ns_ > now) break;
                frame = std::move(*first); frames_.erase(first);
                show = frame.due > last_due_ && frame.due >= now - kVideoLateToleranceNs;
                if (frame.due <= last_due_) { ++order_; ++total_dropped_; }
                else if (!show) { ++late_; ++total_dropped_; }
                else {
                    ++submitted_; ++total_submitted_; lateness_.add(now - frame.due);
                    if (last_submit_) gap_.add(now - last_submit_);
                    last_due_ = frame.due; last_submit_ = now;
                }
            }
            // Never call host code under the scheduler mutex.
            frame.finish(show);
        }
    }
    void clear() {
        std::lock_guard<std::mutex> guard(lock_);
        clear_locked(); generation_ = 0;
    }
    // Resolution changes discard completed pictures but keep the session epoch.
    void flush() {
        std::lock_guard<std::mutex> guard(lock_);
        clear_locked();
    }
    std::string diagnostics(int64_t now = TimingSamples::now_ns()) {
        std::lock_guard<std::mutex> guard(lock_);
        if (!report_at_) report_at_ = now;
        if (now - report_at_ < 5000000000LL) return {};
        if (!(ready_ || submitted_ || late_ || order_ || overflow_ || cancelled_)) {
            report_at_ = now; return {};
        }
        char text[384];
        std::snprintf(text, sizeof(text),
            "Video scheduler: ready=%llu submitted=%llu late_drop=%llu order_drop=%llu overflow_drop=%llu cancelled=%llu pending=%zu peak_pending=%zu decode_ahead=%zu lead_ms=%.1f",
            static_cast<unsigned long long>(ready_), static_cast<unsigned long long>(submitted_),
            static_cast<unsigned long long>(late_), static_cast<unsigned long long>(order_),
            static_cast<unsigned long long>(overflow_), static_cast<unsigned long long>(cancelled_),
            frames_.size(), peak_, decode_ahead_, lead_ns_ / 1e6);
        auto result = std::string(text) + lateness_.text("release_late") + gap_.text("release_gap");
        ready_ = submitted_ = late_ = order_ = overflow_ = cancelled_ = 0;
        peak_ = frames_.size(); lateness_ = {}; gap_ = {}; report_at_ = now;
        return result;
    }
private:
    struct Frame {
        int64_t due = 0;
        std::function<void(bool)> complete;
        Frame() = default;
        Frame(int64_t pts, std::function<void(bool)> callback) : due(pts), complete(std::move(callback)) {}
        Frame(const Frame &) = delete;
        Frame &operator=(const Frame &) = delete;
        Frame(Frame &&other) noexcept : due(other.due), complete(std::move(other.complete)) { other.complete = {}; }
        Frame &operator=(Frame &&other) noexcept {
            if (this != &other) {
                finish(false); due = other.due; complete = std::move(other.complete); other.complete = {};
            }
            return *this;
        }
        ~Frame() { finish(false); }
        void finish(bool show) {
            auto callback = std::move(complete); complete = {};
            if (callback) callback(show);
        }
    };
    static bool earlier(const Frame &a, const Frame &b) { return a.due < b.due; }
    void clear_locked() {
        for (auto &frame : frames_) { frame.finish(false); ++cancelled_; }
        frames_.clear(); last_due_ = last_submit_ = 0;
    }
    mutable std::mutex lock_;
    std::vector<Frame> frames_;
    uint64_t generation_ = 0;
    int64_t lead_ns_, last_due_ = 0, last_submit_ = 0, report_at_ = 0;
    size_t decode_ahead_, peak_ = 0;
    uint64_t total_submitted_ = 0, total_dropped_ = 0;
    uint64_t ready_ = 0, submitted_ = 0, late_ = 0, order_ = 0, overflow_ = 0, cancelled_ = 0;
    TimingSamples lateness_, gap_;
};
} // namespace airplay
