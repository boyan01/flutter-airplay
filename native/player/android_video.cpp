// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include <android/native_window.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <string>
#include <cstring>
#include <stdexcept>
#include <dlfcn.h>

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
    void size(int w, int h) override {
        if (w != width_ || h != height_) { reset(); width_ = w; height_ = h; }
    }
    void reset() override {
        if (codec_) { AMediaCodec_stop(codec_); AMediaCodec_delete(codec_); codec_ = nullptr; }
    }
    bool decode(const VideoPacket &packet) override {
        if (!codec_) {
            bool key = false;
            for (const auto &nal : split_nals(packet.bytes.data(), packet.bytes.size())) key |= (nal[0] & 31) == 7 || (nal[0] & 31) == 5;
            if (!key) return true;
            if (!open(decoder_) && !open(fallback_)) return false;
        }
        generation_ = packet.generation;
        for (int tries = 0; tries < 10; ++tries) {
            auto index = AMediaCodec_dequeueInputBuffer(codec_, 20000);
            if (index >= 0) {
                size_t capacity = 0; auto *bytes = AMediaCodec_getInputBuffer(codec_, index, &capacity);
                if (!bytes || capacity < packet.bytes.size()) return false;
                memcpy(bytes, packet.bytes.data(), packet.bytes.size());
                return AMediaCodec_queueInputBuffer(codec_, index, 0, packet.bytes.size(), packet.deadline / 1000, 0) == AMEDIA_OK;
            }
            drain();
        }
        callbacks_.log("MediaCodec input stalled; waiting for a new keyframe");
        return false;
    }
    void drain() override {
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
            const auto due = info.presentationTimeUs * 1000;
            if (due < monotonic_ns() - 150000000) AMediaCodec_releaseOutputBuffer(codec_, index, false);
            else {
                AMediaCodec_releaseOutputBufferAtTime(codec_, index, due);
                callbacks_.frame(nullptr, visible_width_, visible_height_, due, generation_);
            }
        }
    }
private:
    bool open(const std::string &name) {
        if (name.empty()) return false;
        // Retry without vendor low-latency options when a device rejects them.
        for (int attempt = 0; attempt < 2; ++attempt) {
            auto *candidate = AMediaCodec_createCodecByName(name.c_str());
            if (!candidate) return false;
            auto *format = AMediaFormat_new();
            AMediaFormat_setString(format, "mime", "video/avc");
            AMediaFormat_setInt32(format, "width", width_); AMediaFormat_setInt32(format, "height", height_);
            AMediaFormat_setInt32(format, "max-input-size", std::max(width_ * height_, 4 * 1024 * 1024));
            AMediaFormat_setInt32(format, "frame-rate", 60);
            if (!attempt) AMediaFormat_setInt32(format, "low-latency", 1);
            auto status = AMediaCodec_configure(candidate, format, window_, nullptr, 0);
            AMediaFormat_delete(format);
            if (status == AMEDIA_OK && AMediaCodec_start(candidate) == AMEDIA_OK) {
                codec_ = candidate; visible_width_ = width_; visible_height_ = height_; callbacks_.log(name.c_str()); return true;
            }
            AMediaCodec_delete(candidate);
        }
        return false;
    }
    ANativeWindow *window_;
    AMediaCodec *codec_ = nullptr;
    std::string decoder_, fallback_;
    VideoCallbacks callbacks_;
    int width_ = 1920, height_ = 1080, visible_width_ = 1920, visible_height_ = 1080;
    uint64_t generation_ = 1;
};
std::unique_ptr<VideoOutput> make_video_output(void *surface, const char *decoder, const char *fallback, VideoCallbacks cb) {
    return std::make_unique<AndroidVideo>(surface, decoder, fallback, std::move(cb));
}
} // namespace airplay
