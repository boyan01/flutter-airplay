// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include <AudioToolbox/AudioToolbox.h>
#import <AVFAudio/AVFAudio.h>
#include <mach/mach_time.h>
#include <cstring>

namespace airplay {
// The iOS host owns AVAudioSession activation and interruption recovery.
class IOSAudio final : public AudioOutput {
public:
    explicit IOSAudio(std::shared_ptr<AudioBuffer> buffer) : buffer_(std::move(buffer)) {}
    ~IOSAudio() override { stop(); }
    bool start() override {
        std::lock_guard<std::mutex> guard(lock_);
        if (unit_) return true;
        AudioComponentDescription description{kAudioUnitType_Output, kAudioUnitSubType_RemoteIO,
                                               kAudioUnitManufacturer_Apple, 0, 0};
        auto component = AudioComponentFindNext(nullptr, &description);
        if (!component || AudioComponentInstanceNew(component, &unit_)) { close(); return false; }
        UInt32 enabled = 1;
        AudioStreamBasicDescription format{};
        format.mSampleRate = kSampleRate; format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        format.mBytesPerPacket = format.mBytesPerFrame = 4; format.mFramesPerPacket = 1;
        format.mChannelsPerFrame = 2; format.mBitsPerChannel = 16;
        AURenderCallbackStruct callback{render, this};
        if (AudioUnitSetProperty(unit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, sizeof(enabled)) ||
            AudioUnitSetProperty(unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)) ||
            AudioUnitSetProperty(unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) ||
            AudioUnitInitialize(unit_)) { close(); return false; }
        mach_timebase_info_data_t info{}; mach_timebase_info(&info);
        host_scale_ = double(info.numer) / info.denom;
        host_offset_ = monotonic_ns() - int64_t(mach_absolute_time() * host_scale_);
        // RemoteIO converts the fixed receiver PCM rate to the active route rate.
        latency_ = int64_t(AVAudioSession.sharedInstance.outputLatency * kSecond);
        if (AudioOutputUnitStart(unit_)) { close(); return false; }
        return true;
    }
    void stop() override { std::lock_guard<std::mutex> guard(lock_); close(); }
private:
    void close() {
        if (!unit_) return;
        AudioOutputUnitStop(unit_); AudioUnitUninitialize(unit_);
        AudioComponentInstanceDispose(unit_); unit_ = nullptr;
    }
    static OSStatus render(void *opaque, AudioUnitRenderActionFlags *, const AudioTimeStamp *timestamp,
                           UInt32, UInt32 frames, AudioBufferList *list) {
        auto *self = static_cast<IOSAudio *>(opaque);
        for (UInt32 i = 0; i < list->mNumberBuffers; ++i)
            if (list->mBuffers[i].mData) std::memset(list->mBuffers[i].mData, 0, list->mBuffers[i].mDataByteSize);
        if (list->mNumberBuffers == 1 && list->mBuffers[0].mData && list->mBuffers[0].mDataByteSize >= frames * 4) {
            const auto time = timestamp->mFlags & kAudioTimeStampHostTimeValid
                ? int64_t(timestamp->mHostTime * self->host_scale_) + self->host_offset_ : monotonic_ns();
            self->buffer_->read(static_cast<int16_t *>(list->mBuffers[0].mData), frames, time + self->latency_);
        }
        return noErr;
    }
    std::mutex lock_;
    std::shared_ptr<AudioBuffer> buffer_;
    AudioUnit unit_ = nullptr;
    double host_scale_ = 1;
    int64_t host_offset_ = 0, latency_ = 0;
};
std::unique_ptr<AudioOutput> make_audio_output(std::shared_ptr<AudioBuffer> buffer) {
    return std::make_unique<IOSAudio>(std::move(buffer));
}
} // namespace airplay
