// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "timeline.h"
#include <functional>
#include <memory>
#include <mutex>

namespace airplay {
class AudioDecoder {
public:
    AudioDecoder(std::shared_ptr<AudioBuffer> buffer, std::function<void(const char *)> log);
    ~AudioDecoder();
    void format(int ct, int spf) {
        std::lock_guard<std::mutex> guard(lock_);
        if (spf <= 0) spf = default_samples(ct);
        if (ct_ != ct || spf_ != spf) { open_error_logged_ = false; clear(); ct_ = ct; spf_ = spf; }
    }
    void flush() {
        std::lock_guard<std::mutex> guard(lock_);
        clear();
        open_error_logged_ = false;
        buffer_->flush();
    }
    bool decode(const uint8_t *data, size_t size, int ct, int64_t deadline, bool *produced = nullptr) {
        if (produced) *produced = false;
        std::lock_guard<std::mutex> guard(lock_);
        if (!data || !size || size > 65536 || (ct != 2 && ct != 4 && ct != 8)) return false;
        if (ct != ct_) { open_error_logged_ = false; clear(); ct_ = ct; spf_ = default_samples(ct); }
        if (!codec_ && !open()) return false;
        const auto decoded = decode_packet(data, size, deadline, buffer_->generation(), produced);
        // A failed codec may have changed its output format or consumed only
        // part of the packet. Recreate it before accepting more compressed data.
        if (!decoded) clear();
        return decoded;
    }
private:
    struct Codec;
    static int default_samples(int ct) { return ct == 2 ? 352 : ct == 4 ? 1024 : 480; }
    void clear();
    bool open();
    bool decode_packet(const uint8_t *, size_t, int64_t, uint64_t, bool *);
    void write_pcm(const int16_t *pcm, size_t frames, int64_t deadline, uint64_t generation, bool *produced) {
        const auto written = buffer_->write(pcm, frames, deadline, generation);
        if (produced && written) *produced = true;
        if (written != frames) log_("Audio queue full; dropping stale backlog input");
    }
    std::mutex lock_;
    std::shared_ptr<AudioBuffer> buffer_;
    std::function<void(const char *)> log_;
    std::unique_ptr<Codec> codec_;
    int ct_ = 8, spf_ = 480;
    bool open_error_logged_ = false;
};
} // namespace airplay
