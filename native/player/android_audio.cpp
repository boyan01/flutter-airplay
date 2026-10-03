// SPDX-License-Identifier: GPL-3.0-only
// Device-loss handling follows jqssun/android-airplay-server; see android/NOTICE.
#include "platform.h"
#include "audio_clock.h"
#include <oboe/Oboe.h>

namespace airplay {
class AndroidAudio;
class AudioCallbacks final : public oboe::AudioStreamDataCallback, public oboe::AudioStreamErrorCallback {
public:
    explicit AudioCallbacks(std::shared_ptr<AudioBuffer> buffer) : buffer_(std::move(buffer)) {}
    oboe::DataCallbackResult onAudioReady(oboe::AudioStream *stream, void *data, int32_t frames) override {
        const auto now = monotonic_ns();
        auto due = now + int64_t(stream->getBufferSizeInFrames()) * kSecond / stream->getSampleRate();
        int64_t position = 0, timestamp = 0;
        if (stream->getTimestamp(CLOCK_MONOTONIC, &position, &timestamp) == oboe::Result::OK) {
            const auto estimated = timestamp + (stream->getFramesWritten() - position) * kSecond / stream->getSampleRate();
            if (estimated >= now && estimated < now + kSecond / 2) due = estimated;
        }
        due = clock_.next(frames, due);
        buffer_->read(static_cast<int16_t *>(data), frames, due);
        return oboe::DataCallbackResult::Continue;
    }
    void onErrorAfterClose(oboe::AudioStream *, oboe::Result) override;
    std::weak_ptr<AndroidAudio> owner;
    void resetClock() { clock_.reset(); }
private:
    AudioClock clock_;
    std::shared_ptr<AudioBuffer> buffer_;
};
class AndroidAudio final : public AudioOutput {
public:
    explicit AndroidAudio(std::shared_ptr<AudioBuffer> buffer) : callbacks_(std::make_shared<AudioCallbacks>(std::move(buffer))) {}
    ~AndroidAudio() override { stop(); }
    bool start() override {
        std::lock_guard<std::mutex> guard(lock_);
        if (stream_) return true;
        closing_ = false; return open();
    }
    void stop() override {
        std::lock_guard<std::mutex> guard(lock_);
        closing_ = true;
        if (stream_) { stream_->stop(); stream_->close(); stream_.reset(); }
    }
    void reopen() {
        std::lock_guard<std::mutex> guard(lock_);
        if (!closing_) { stream_.reset(); open(); }
    }
    std::shared_ptr<AudioCallbacks> callbacks_;
private:
    bool open() {
        callbacks_->resetClock();
        oboe::AudioStreamBuilder builder;
        builder.setDirection(oboe::Direction::Output)->setSharingMode(oboe::SharingMode::Shared)
            ->setFormat(oboe::AudioFormat::I16)->setChannelCount(2)->setSampleRate(kSampleRate)
            ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)->setUsage(oboe::Usage::Media)
            ->setDataCallback(callbacks_)->setErrorCallback(callbacks_);
        if (builder.openStream(stream_) != oboe::Result::OK) return false;
        stream_->setBufferSizeInFrames(stream_->getFramesPerBurst() * 2);
        if (stream_->requestStart() != oboe::Result::OK) { stream_->close(); stream_.reset(); return false; }
        return true;
    }
    std::mutex lock_;
    bool closing_ = false;
    std::shared_ptr<oboe::AudioStream> stream_;
};
void AudioCallbacks::onErrorAfterClose(oboe::AudioStream *, oboe::Result) { if (auto output = owner.lock()) output->reopen(); }
// Oboe can deliver late error callbacks. The callbacks retain PCM, and only weakly
// reference the output, just as the previous Android adapter did.
class OwnedAudio final : public AudioOutput {
public:
    explicit OwnedAudio(std::shared_ptr<AudioBuffer> buffer) : output_(std::make_shared<AndroidAudio>(std::move(buffer))) {
        output_->callbacks_->owner = output_;
    }
    bool start() override { return output_->start(); }
    void stop() override { output_->stop(); }
private:
    std::shared_ptr<AndroidAudio> output_;
};
std::unique_ptr<AudioOutput> make_audio_output(std::shared_ptr<AudioBuffer> buffer) {
    return std::make_unique<OwnedAudio>(std::move(buffer));
}
} // namespace airplay
