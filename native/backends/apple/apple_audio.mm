// SPDX-License-Identifier: GPL-3.0-only
#include "../../playback/platform.h"
#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <AVFAudio/AVFAudio.h>
#endif
#include <mach/mach_time.h>
#include <cstdio>
#include <cstring>

namespace airplay {
class AppleAudio final : public AudioOutput {
public:
    explicit AppleAudio(std::shared_ptr<AudioBuffer> buffer) : buffer_(std::move(buffer)) {}
    ~AppleAudio() override { stop(); }
    bool start() override {
        std::lock_guard<std::mutex> guard(lock_);
        if (unit_) return true;
#if TARGET_OS_IPHONE
        constexpr auto subtype = kAudioUnitSubType_RemoteIO;
#else
        constexpr auto subtype = kAudioUnitSubType_DefaultOutput;
#endif
        AudioComponentDescription description{kAudioUnitType_Output, subtype, kAudioUnitManufacturer_Apple, 0, 0};
        auto component = AudioComponentFindNext(nullptr, &description);
        if (!component || AudioComponentInstanceNew(component, &unit_)) { close(); return false; }
#if TARGET_OS_IPHONE
        UInt32 enabled = 1;
        if (AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                &enabled, sizeof(enabled))) { close(); return false; }
#endif
        AudioStreamBasicDescription format{};
        format.mSampleRate = kSampleRate; format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        format.mBytesPerPacket = format.mBytesPerFrame = 4; format.mFramesPerPacket = 1;
        format.mChannelsPerFrame = 2; format.mBitsPerChannel = 16;
        AURenderCallbackStruct callback{render, this};
        if (AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)) ||
            AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) ||
            AudioUnitInitialize(unit_)) { close(); return false; }
        mach_timebase_info_data_t info{}; mach_timebase_info(&info);
        host_scale_ = double(info.numer) / info.denom;
        host_offset_ = monotonic_ns() - int64_t(mach_absolute_time() * host_scale_);
#if TARGET_OS_IPHONE
        // The host owns AVAudioSession activation and interruption recovery.
        latency_ = int64_t(AVAudioSession.sharedInstance.outputLatency * kSecond);
#else
        Float64 latency = 0; UInt32 bytes = sizeof(latency);
        if (!AudioUnitGetProperty(unit_, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &bytes))
            latency_ = int64_t(latency * kSecond);
#endif
        if (AudioOutputUnitStart(unit_)) { close(); return false; }
        return true;
    }
    void stop() override { std::lock_guard<std::mutex> guard(lock_); close(); }
    std::string diagnostics() override {
        std::lock_guard<std::mutex> guard(lock_);
        char message[512];
        std::snprintf(message, sizeof(message),
            "AudioUnit output: state=%s rate=%d callbacks_total=%llu frames_total=%llu nonzero_frames_total=%llu invalid_buffers_total=%llu pcm_late_drop_total=%llu pcm_stale_drop_total=%llu max_callback_gap_ms=%.1f max_timestamp_step_ms=%.1f last_callback_age_ms=%.1f gain=%.3f",
            unit_ ? "running" : "closed", kSampleRate,
            static_cast<unsigned long long>(callbacks_.load()), static_cast<unsigned long long>(frames_.load()),
            static_cast<unsigned long long>(nonzero_.load()), static_cast<unsigned long long>(invalid_buffers_.load()),
            static_cast<unsigned long long>(buffer_->late_drops()), static_cast<unsigned long long>(buffer_->stale_drops()),
            max_callback_gap_.exchange(0) / 1e6, max_timestamp_step_.exchange(0) / 1e6,
            last_callback_.load() ? double(monotonic_ns() - last_callback_.load()) / 1e6 : -1, buffer_->gain());
        return message;
    }
private:
    void read(int16_t *pcm, UInt32 frames, int64_t time) {
        const auto now = monotonic_ns();
        if (last_callback_) record_max(max_callback_gap_, now - last_callback_);
        if (last_time_) record_max(max_timestamp_step_, std::abs(time - last_time_ - int64_t(last_frames_) * kSecond / kSampleRate));
        last_callback_ = now; last_time_ = time; last_frames_ = frames;
        buffer_->read(pcm, frames, time);
        ++callbacks_; frames_ += frames;
        uint64_t nonzero = 0;
        for (UInt32 i = 0; i < frames; ++i) nonzero += pcm[i * 2] != 0 || pcm[i * 2 + 1] != 0;
        nonzero_ += nonzero;
    }
    static void record_max(std::atomic<int64_t> &target, int64_t value) {
        auto previous = target.load(std::memory_order_relaxed);
        while (value > previous && !target.compare_exchange_weak(previous, value, std::memory_order_relaxed)) {}
    }
    void close() {
        if (unit_) { AudioOutputUnitStop(unit_); AudioUnitUninitialize(unit_); AudioComponentInstanceDispose(unit_); unit_ = nullptr; }
        last_callback_ = 0; last_time_ = 0; last_frames_ = 0;
    }
    static OSStatus render(void *opaque, AudioUnitRenderActionFlags *, const AudioTimeStamp *timestamp,
                           UInt32, UInt32 frames, AudioBufferList *list) {
        auto *self = static_cast<AppleAudio *>(opaque);
        for (UInt32 i = 0; i < list->mNumberBuffers; ++i)
            if (list->mBuffers[i].mData) std::memset(list->mBuffers[i].mData, 0, list->mBuffers[i].mDataByteSize);
        const auto time = timestamp->mFlags & kAudioTimeStampHostTimeValid
            ? int64_t(timestamp->mHostTime * self->host_scale_) + self->host_offset_ : monotonic_ns();
        if (list->mNumberBuffers == 1 && list->mBuffers[0].mData && list->mBuffers[0].mDataByteSize >= frames * 4)
            self->read(static_cast<int16_t *>(list->mBuffers[0].mData), frames, time + self->latency_);
        else ++self->invalid_buffers_;
        return noErr;
    }
    std::mutex lock_;
    std::shared_ptr<AudioBuffer> buffer_;
    AudioUnit unit_ = nullptr;
    double host_scale_ = 1;
    int64_t host_offset_ = 0, latency_ = 0;
    std::atomic<int64_t> last_callback_{0};
    int64_t last_time_ = 0;
    UInt32 last_frames_ = 0;
    std::atomic<uint64_t> callbacks_{0}, frames_{0}, nonzero_{0}, invalid_buffers_{0};
    std::atomic<int64_t> max_callback_gap_{0}, max_timestamp_step_{0};
};
std::unique_ptr<AudioOutput> make_audio_output(std::shared_ptr<AudioBuffer> buffer) {
    return std::make_unique<AppleAudio>(std::move(buffer));
}
} // namespace airplay
