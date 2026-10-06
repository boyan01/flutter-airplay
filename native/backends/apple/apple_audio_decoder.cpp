// SPDX-License-Identifier: GPL-3.0-only
// AirPlay ALAC configuration derived from jqssun/android-airplay-server;
// see THIRD_PARTY_NOTICES.md and android/NOTICE.
#include "../../playback/audio_decoder.h"
#include <AudioToolbox/AudioToolbox.h>
#include <array>
#include <cstring>

namespace airplay {
struct AudioDecoder::Codec {
    AudioConverterRef converter = nullptr;
    ~Codec() { if (converter) AudioConverterDispose(converter); }
};
AudioDecoder::AudioDecoder(std::shared_ptr<AudioBuffer> buffer, std::function<void(const char *)> log)
    : buffer_(std::move(buffer)), log_(std::move(log)) {}
AudioDecoder::~AudioDecoder() = default;
void AudioDecoder::clear() { codec_.reset(); }

bool AudioDecoder::open() {
    if (spf_ <= 0 || spf_ > 16384 || (ct_ == 4 && spf_ != 960 && spf_ != 1024)
        || (ct_ == 8 && spf_ != 480 && spf_ != 512)) return false;
    AudioStreamBasicDescription input{};
    input.mSampleRate = kSampleRate; input.mChannelsPerFrame = 2; input.mFramesPerPacket = spf_;
    input.mFormatID = ct_ == 2 ? kAudioFormatAppleLossless : ct_ == 8 ? kAudioFormatMPEG4AAC_ELD : kAudioFormatMPEG4AAC;
    input.mFormatFlags = ct_ == 2 ? kAppleLosslessFormatFlag_16BitSourceData : ct_ == 4 ? kMPEG4Object_AAC_LC : 0;
    AudioStreamBasicDescription output{};
    output.mSampleRate = kSampleRate; output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    output.mBytesPerPacket = output.mBytesPerFrame = 4; output.mFramesPerPacket = 1;
    output.mChannelsPerFrame = 2; output.mBitsPerChannel = 16;
    auto candidate = std::make_unique<Codec>();
    if (AudioConverterNew(&input, &output, &candidate->converter)) return false;
    if (ct_ == 2) {
        std::array<uint8_t, 24> cookie{};
        cookie[0] = spf_ >> 24; cookie[1] = spf_ >> 16; cookie[2] = spf_ >> 8; cookie[3] = spf_;
        cookie[5] = 16; cookie[6] = 40; cookie[7] = 10; cookie[8] = 14; cookie[9] = 2; cookie[11] = 255;
        cookie[22] = (kSampleRate >> 8) & 255; cookie[23] = kSampleRate & 255;
        if (AudioConverterSetProperty(candidate->converter, kAudioConverterDecompressionMagicCookie,
                                      cookie.size(), cookie.data())) return false;
    }
    codec_ = std::move(candidate);
    log_(ct_ == 2 ? "AudioConverter ALAC decoder ready" : ct_ == 8 ? "AudioConverter AAC-ELD decoder ready" : "AudioConverter AAC decoder ready");
    return true;
}

bool AudioDecoder::decode_packet(const uint8_t *data, size_t size, int64_t deadline, uint64_t generation, bool *produced) {
    struct Input {
        const uint8_t *data;
        UInt32 size, frames;
        bool consumed = false;
        AudioStreamPacketDescription packet{};
    } input{data, UInt32(size), UInt32(spf_)};
    auto supply = [](AudioConverterRef, UInt32 *count, AudioBufferList *list,
                     AudioStreamPacketDescription **description, void *context) -> OSStatus {
        auto &input = *static_cast<Input *>(context);
        // Temporarily exhausted live input is not end-of-stream.
        if (input.consumed) { *count = 0; return 'wait'; }
        input.consumed = true;
        *count = 1; list->mNumberBuffers = 1;
        list->mBuffers[0] = {2, input.size, const_cast<uint8_t *>(input.data)};
        input.packet = {0, input.frames, input.size};
        if (description) *description = &input.packet;
        return noErr;
    };
    std::vector<int16_t> pcm(size_t(spf_) * 2);
    for (;;) {
        AudioBufferList output{}; output.mNumberBuffers = 1;
        output.mBuffers[0] = {2, UInt32(pcm.size() * sizeof(int16_t)), pcm.data()};
        UInt32 frames = spf_;
        const auto status = AudioConverterFillComplexBuffer(codec_->converter, supply, &input, &frames, &output, nullptr);
        if ((status && status != 'wait') || frames > uint32_t(spf_)) return false;
        if (frames) {
            write_pcm(pcm.data(), frames, deadline, generation, produced);
            deadline += int64_t(frames) * kSecond / kSampleRate;
        }
        if (status == 'wait') return true;
        if (!frames) return true;
    }
}
} // namespace airplay
