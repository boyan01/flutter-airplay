// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "video_scheduler.h"
#include <android/native_window.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <string>
#include <cstring>
#include <stdexcept>
#include <dlfcn.h>
#include <cstdio>
#include <deque>
#include <mutex>

namespace airplay {
class AndroidVideo final : public VideoOutput {
public:
    AndroidVideo(void *surface, const char *decoder, const char *fallback, VideoCallbacks callbacks)
        : window_(static_cast<ANativeWindow *>(surface)), decoder_(decoder ? decoder : ""),
          fallback_(fallback ? fallback : ""), callbacks_(std::move(callbacks)) {
        if (!window_) throw std::runtime_error("Missing Android playback surface");
        ANativeWindow_acquire(window_);
    }
    ~AndroidVideo() override { reset(); ANativeWindow_release(window_); }
    bool supports_hevc() const override { return !hevc_decoder_.empty(); }
    bool set_hevc_decoder(const char *name) override {
        std::lock_guard<std::recursive_mutex> guard(surface_lock_);
        if (codec_ || !name) return false;
        hevc_decoder_ = name;
        return true;
    }
    bool set_surface(void *surface) override {
        std::lock_guard<std::recursive_mutex> guard(surface_lock_);
        auto *next = static_cast<ANativeWindow *>(surface);
        if (!next) return false;
        if (next == window_) return true;
        ANativeWindow_acquire(next);
        if (codec_ && AMediaCodec_setOutputSurface(codec_, next) != AMEDIA_OK) {
            ANativeWindow_release(next);
            callbacks_.log("Android video surface switch failed");
            return false;
        }
        ANativeWindow_release(window_);
        window_ = next;
        callbacks_.log("Android video surface switched without decoder reset");
        return true;
    }
    void size(int w, int h) override {
        std::lock_guard<std::recursive_mutex> guard(surface_lock_);
        if (w != width_ || h != height_) {
            char message[128];
            std::snprintf(message, sizeof(message), "Android video resize: old=%dx%d new=%dx%d", width_, height_, w, h);
            callbacks_.log(message);
            reset(); width_ = w; height_ = h;
        }
    }
    void reset() override {
        std::lock_guard<std::recursive_mutex> guard(surface_lock_);
        report_stats(true);
        stats_started_ = 0; submitted_ = 0;
        scheduler_.clear();
        inputs_.clear();
        max_queue_ns_ = max_input_wait_ns_ = max_decode_ns_ = 0;
        decoded_ = unmatched_ = 0;
        if (codec_) {
            const auto begin = monotonic_ns();
            AMediaCodec_stop(codec_); AMediaCodec_delete(codec_); codec_ = nullptr;
            char message[128];
            std::snprintf(message, sizeof(message), "Android video decoder stop: elapsed_ms=%.1f", (monotonic_ns() - begin) / 1000000.0);
            callbacks_.log(message);
        }
    }
    bool decode(const VideoPacket &packet) override {
        std::lock_guard<std::recursive_mutex> guard(surface_lock_);
        const auto entered = monotonic_ns();
        if (packet.hevc != hevc_) { reset(); hevc_ = packet.hevc; }
        if (hevc_ && !supports_hevc()) return false;
        if (packet.received_ns) max_queue_ns_ = std::max(max_queue_ns_, entered - packet.received_ns);
        if (!codec_) {
            bool key = false;
            for (const auto &nal : split_nals(packet.bytes.data(), packet.bytes.size())) {
                if (hevc_ && (nal.size() < 2 || (nal[0] & 0x80) || !(nal[1] & 7))) return false;
                const auto type = hevc_ ? (nal[0] >> 1) & 63 : nal[0] & 31;
                key |= hevc_ ? type == 32 || (type >= 16 && type <= 23) : type == 7 || type == 5;
            }
            if (!key) return true;
            if (hevc_) {
                if (!open(hevc_decoder_)) return false;
            } else if (!open(decoder_) && !open(fallback_)) return false;
        }
        generation_ = packet.generation;
        scheduler_.begin(packet.generation);
        const auto timeout = monotonic_ns() + 200000000;
        do {
            // Held output buffers can backpressure input. Keep presenting while
            // waiting for an input slot, without adding a 20 ms presentation gap.
            drain();
            auto index = AMediaCodec_dequeueInputBuffer(codec_, 1000);
            if (index >= 0) {
                size_t capacity = 0; auto *bytes = AMediaCodec_getInputBuffer(codec_, index, &capacity);
                if (!bytes || capacity < packet.bytes.size()) return false;
                memcpy(bytes, packet.bytes.data(), packet.bytes.size());
                const auto status = AMediaCodec_queueInputBuffer(codec_, index, 0, packet.bytes.size(), packet.deadline / 1000, 0);
                if (status == AMEDIA_OK) {
                    ++submitted_;
                    const auto queued = monotonic_ns();
                    max_input_wait_ns_ = std::max(max_input_wait_ns_, queued - entered);
                    // Bound diagnostic bookkeeping even if a codec never produces output.
                    if (inputs_.size() == 512) inputs_.pop_front();
                    inputs_.push_back({packet.deadline / 1000, queued});
                }
                return status == AMEDIA_OK;
            }
            if (index != AMEDIACODEC_INFO_TRY_AGAIN_LATER) return false;
        } while (monotonic_ns() < timeout);
        callbacks_.log("MediaCodec input stalled; waiting for a new keyframe");
        return false;
    }
    bool can_decode() const override {
        std::lock_guard<std::recursive_mutex> guard(surface_lock_);
        return scheduler_.can_decode();
    }
    int64_t next_deadline() const override {
        std::lock_guard<std::recursive_mutex> guard(surface_lock_);
        return scheduler_.next_deadline();
    }
    void drain() override {
        std::lock_guard<std::recursive_mutex> guard(surface_lock_);
        if (!codec_) return;
        AMediaCodecBufferInfo info{};
        while (true) {
            auto index = AMediaCodec_dequeueOutputBuffer(codec_, &info, 0);
            if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
                auto *format = AMediaCodec_getOutputFormat(codec_);
                callbacks_.log(AMediaFormat_toString(format));
                int32_t w, h, left, right, top, bottom;
                if (AMediaFormat_getInt32(format, "width", &w) && AMediaFormat_getInt32(format, "height", &h)) {
                    // API 28+ stores crop as a rectangle; resolve optionally so API 26 still loads.
                    using GetRect = bool (*)(AMediaFormat *, const char *, int32_t *, int32_t *, int32_t *, int32_t *);
                    static auto get_rect = reinterpret_cast<GetRect>(dlsym(RTLD_DEFAULT, "AMediaFormat_getRect"));
                    if (get_rect && get_rect(format, "crop", &left, &top, &right, &bottom)) {
                        w = right-left+1; h = bottom-top+1;
                    } else {
                        if (AMediaFormat_getInt32(format, "crop-left", &left) && AMediaFormat_getInt32(format, "crop-right", &right)) w = right-left+1;
                        if (AMediaFormat_getInt32(format, "crop-top", &top) && AMediaFormat_getInt32(format, "crop-bottom", &bottom)) h = bottom-top+1;
                    }
                    visible_width_ = w; visible_height_ = h;
                }
                AMediaFormat_delete(format); continue;
            }
            if (index < 0) break;
            ++decoded_;
            // Includes codec buffering and worker polling delay, not hardware decode time alone.
            const auto input = std::find_if(inputs_.begin(), inputs_.end(),
                [&](const InputTiming &value) { return value.pts_us == info.presentationTimeUs; });
            if (input != inputs_.end()) {
                max_decode_ns_ = std::max(max_decode_ns_, monotonic_ns() - input->queued_ns);
                inputs_.erase(input);
            } else ++unmatched_;
            const auto due = info.presentationTimeUs * 1000;
            const auto generation = generation_;
            const auto w = visible_width_, h = visible_height_;
            scheduler_.enqueue(due, generation, [this, index, due, generation, w, h](bool show) {
                if (show) {
                    AMediaCodec_releaseOutputBufferAtTime(codec_, index, due);
                    if (callbacks_.frame) callbacks_.frame(nullptr, w, h, due, generation);
                } else AMediaCodec_releaseOutputBuffer(codec_, index, false);
            });
        }
        // Collect decode-order output first, then release by presentation time.
        scheduler_.drain();
        const auto schedule = scheduler_.diagnostics();
        if (!schedule.empty() && callbacks_.log) callbacks_.log(schedule.c_str());
        report_stats(false);
    }
private:
    mutable std::recursive_mutex surface_lock_;
    void report_stats(bool final) {
        const auto now = monotonic_ns();
        if (!stats_started_) { stats_started_ = now; return; }
        const auto elapsed = now - stats_started_;
        if ((!final && elapsed < 5000000000LL) || !(submitted_ || decoded_)) return;
        char message[512];
        std::snprintf(message, sizeof(message),
            "Android video stats: interval_ms=%lld input=%llu decoded=%llu unmatched_output=%llu max_queue_ms=%.1f max_input_wait_ms=%.1f max_decode_observed_ms=%.1f size=%dx%d%s",
            static_cast<long long>(elapsed / 1000000),
            static_cast<unsigned long long>(submitted_), static_cast<unsigned long long>(decoded_),
            static_cast<unsigned long long>(unmatched_), max_queue_ns_ / 1e6,
            max_input_wait_ns_ / 1e6, max_decode_ns_ / 1e6,
            visible_width_, visible_height_, final ? " final" : "");
        callbacks_.log(message);
        stats_started_ = now; submitted_ = decoded_ = unmatched_ = 0;
        max_queue_ns_ = max_input_wait_ns_ = max_decode_ns_ = 0;
    }
    bool open(const std::string &name) {
        const auto begin = monotonic_ns();
        if (name.empty()) return false;
        const bool qualcomm = !hevc_ && (name.rfind("c2.qti.", 0) == 0 || name.rfind("OMX.qcom.", 0) == 0);
        const int attempts = qualcomm ? 3 : 2;
        // Retry standard low latency, then plain configuration, if a vendor
        // rejects decode-order output. Other decoders keep their existing path.
        for (int attempt = 0; attempt < attempts; ++attempt) {
            auto *candidate = AMediaCodec_createCodecByName(name.c_str());
            if (!candidate) return false;
            auto *format = AMediaFormat_new();
            AMediaFormat_setString(format, "mime", hevc_ ? "video/hevc" : "video/avc");
            AMediaFormat_setInt32(format, "width", width_); AMediaFormat_setInt32(format, "height", height_);
            AMediaFormat_setInt32(format, "max-input-size", std::max(width_ * height_, 4 * 1024 * 1024));
            AMediaFormat_setInt32(format, "frame-rate", 60);
            if (attempt < attempts - 1) AMediaFormat_setInt32(format, "low-latency", 1);
            // Qualcomm otherwise buffers POC type 0 streams without a VUI
            // reorder limit, even when Android low-latency mode is enabled.
            // Presentation ordering remains owned by drain(), not the codec.
            if (qualcomm && !attempt) AMediaFormat_setInt32(format, "vendor.qti-ext-dec-picture-order.enable", 1);
            auto status = AMediaCodec_configure(candidate, format, window_, nullptr, 0);
            AMediaFormat_delete(format);
            if (status == AMEDIA_OK && AMediaCodec_start(candidate) == AMEDIA_OK) {
                codec_ = candidate; visible_width_ = width_; visible_height_ = height_; callbacks_.log(name.c_str());
                char message[256];
                std::snprintf(message, sizeof(message), "Android video decoder open: codec=%s decoder=%s attempt=%d elapsed_ms=%.1f size=%dx%d",
                    hevc_ ? "HEVC" : "H.264", name.c_str(), attempt + 1, (monotonic_ns() - begin) / 1000000.0, width_, height_);
                callbacks_.log(message); return true;
            }
            AMediaCodec_delete(candidate);
        }
        return false;
    }
    ANativeWindow *window_;
    AMediaCodec *codec_ = nullptr;
    struct InputTiming { int64_t pts_us, queued_ns; };
    std::deque<InputTiming> inputs_;
    int64_t max_queue_ns_ = 0, max_input_wait_ns_ = 0, max_decode_ns_ = 0;
    uint64_t decoded_ = 0, unmatched_ = 0;
    // Decode-order MediaCodec output needs room for reference pictures and
    // their B-frames. The codec pool provides the tighter resource bound.
    VideoScheduler scheduler_{0, 16};
    int64_t stats_started_ = 0;
    uint64_t submitted_ = 0;
    std::string decoder_, fallback_;
    std::string hevc_decoder_;
    bool hevc_ = false;
    VideoCallbacks callbacks_;
    int width_ = 1920, height_ = 1080, visible_width_ = 1920, visible_height_ = 1080;
    uint64_t generation_ = 1;
};
std::unique_ptr<VideoOutput> make_video_output(void *surface, const char *decoder, const char *fallback, VideoCallbacks cb) {
    return std::make_unique<AndroidVideo>(surface, decoder, fallback, std::move(cb));
}
} // namespace airplay
