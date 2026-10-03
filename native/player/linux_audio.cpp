// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "audio_clock.h"
#include <pulse/pulseaudio.h>
#include <array>
#include <chrono>
#include <condition_variable>
#include <vector>

namespace airplay {
// PulseAudio also works with PipeWire's PulseAudio-compatible server. The device
// callback consumes the common queue on its presentation clock, not wall time.
class LinuxAudio final : public AudioOutput {
public:
    explicit LinuxAudio(std::shared_ptr<AudioBuffer> buffer) : buffer_(std::move(buffer)) {}
    ~LinuxAudio() override { stop(); }
    bool start() override {
        std::lock_guard<std::mutex> guard(lifecycle_);
        if (ready_) return true;
        close();
        loop_ = pa_threaded_mainloop_new();
        if (!loop_) return false;
        context_ = pa_context_new(pa_threaded_mainloop_get_api(loop_), "Flutter AirPlay");
        if (!context_) { close(); return false; }
        pa_context_set_state_callback(context_, context_state, this);
        if (pa_context_connect(context_, nullptr, PA_CONTEXT_NOAUTOSPAWN, nullptr) < 0 ||
            pa_threaded_mainloop_start(loop_) < 0) { close(); return false; }
        started_ = true;
        {
            std::unique_lock<std::mutex> lock(state_lock_);
            changed_.wait_for(lock, std::chrono::seconds(3), [this] { return ready_ || failed_; });
        }
        if (!ready_) { close(); return false; }
        return true;
    }
    void stop() override {
        std::lock_guard<std::mutex> guard(lifecycle_);
        close();
    }
private:
    static void context_state(pa_context *context, void *userdata) {
        auto *self = static_cast<LinuxAudio *>(userdata);
        const auto state = pa_context_get_state(context);
        if (state == PA_CONTEXT_READY) self->open_stream();
        else if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) self->state(false, true);
    }
    void state(bool ready, bool failed) {
        { std::lock_guard<std::mutex> guard(state_lock_); ready_ = ready; failed_ = failed; }
        changed_.notify_all();
    }
    void open_stream() {
        const pa_sample_spec spec{PA_SAMPLE_S16NE, kSampleRate, 2};
        stream_ = pa_stream_new(context_, "AirPlay audio", &spec, nullptr);
        if (!stream_) { state(false, true); return; }
        pa_stream_set_state_callback(stream_, [](pa_stream *stream, void *userdata) {
            auto *self = static_cast<LinuxAudio *>(userdata);
            const auto current = pa_stream_get_state(stream);
            if (current == PA_STREAM_READY) self->state(true, false);
            else if (current == PA_STREAM_FAILED || current == PA_STREAM_TERMINATED) self->state(false, true);
        }, this);
        pa_stream_set_write_callback(stream_, write, this);
        pa_buffer_attr attr{};
        attr.maxlength = uint32_t(pa_usec_to_bytes(80000, &spec));
        attr.tlength = uint32_t(pa_usec_to_bytes(20000, &spec));
        attr.prebuf = 0;
        attr.minreq = uint32_t(pa_usec_to_bytes(5000, &spec));
        attr.fragsize = uint32_t(-1);
        const auto flags = pa_stream_flags_t(PA_STREAM_ADJUST_LATENCY |
            PA_STREAM_AUTO_TIMING_UPDATE | PA_STREAM_INTERPOLATE_TIMING);
        if (pa_stream_connect_playback(stream_, nullptr, &attr, flags, nullptr, nullptr) < 0) state(false, true);
    }
    static void write(pa_stream *stream, size_t bytes, void *userdata) {
        auto *self = static_cast<LinuxAudio *>(userdata);
        // Keep callback work bounded even if the server requests a large refill.
        std::array<int16_t, 4096> pcm{};
        const auto generation = self->buffer_->generation();
        if (self->generation_ != generation) {
            // Drop server-side queued old-session PCM at the next device pull.
            // Samples already delivered to hardware cannot be recalled.
            if (auto *operation = pa_stream_flush(stream, nullptr, nullptr)) pa_operation_unref(operation);
            self->generation_ = generation;
            self->clock_.reset();
        }
        pa_usec_t latency = 0;
        int negative = 0;
        const auto now = monotonic_ns();
        int64_t estimate = now + 20000000;
        if (pa_stream_get_latency(stream, &latency, &negative) == 0 && latency < 500000)
            estimate = now + (negative ? 0 : int64_t(latency) * 1000);
        size_t written = 0;
        while (bytes >= 4) {
            const auto frames = std::min(bytes / 4, pcm.size() / 2);
            self->buffer_->read(pcm.data(), frames, self->clock_.next(frames,
                estimate + int64_t(written) * kSecond / kSampleRate));
            if (pa_stream_write(stream, pcm.data(), frames * 4, nullptr, 0, PA_SEEK_RELATIVE) < 0) {
                self->state(false, true); return;
            }
            bytes -= frames * 4;
            written += frames;
        }
    }
    void close() {
        // Stop and join the Pulse thread before freeing callback-owned objects.
        if (started_) pa_threaded_mainloop_stop(loop_);
        started_ = false;
        if (stream_) {
            pa_stream_set_write_callback(stream_, nullptr, nullptr);
            pa_stream_set_state_callback(stream_, nullptr, nullptr);
            pa_stream_disconnect(stream_); pa_stream_unref(stream_); stream_ = nullptr;
        }
        if (context_) {
            pa_context_set_state_callback(context_, nullptr, nullptr);
            pa_context_disconnect(context_); pa_context_unref(context_); context_ = nullptr;
        }
        if (loop_) { pa_threaded_mainloop_free(loop_); loop_ = nullptr; }
        clock_.reset(); generation_ = buffer_->generation(); ready_ = false; failed_ = false;
    }
    std::shared_ptr<AudioBuffer> buffer_;
    AudioClock clock_;
    uint64_t generation_ = 0;
    std::mutex lifecycle_, state_lock_;
    std::condition_variable changed_;
    std::atomic<bool> ready_{false}, failed_{false};
    bool started_ = false;
    pa_threaded_mainloop *loop_ = nullptr;
    pa_context *context_ = nullptr;
    pa_stream *stream_ = nullptr;
};
std::unique_ptr<AudioOutput> make_audio_output(std::shared_ptr<AudioBuffer> buffer) {
    return std::make_unique<LinuxAudio>(std::move(buffer));
}
} // namespace airplay
