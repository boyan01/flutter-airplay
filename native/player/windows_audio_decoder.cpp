// SPDX-License-Identifier: GPL-3.0-only
#include "audio_decoder.h"
#include "alac_decoder.h"
#include "windows_media.h"
#include <deque>

namespace airplay {
struct AudioDecoder::Codec {
    std::unique_ptr<AlacDecoder> alac;
    ComPtr<IMFTransform> aac;
    std::deque<std::pair<int64_t, uint64_t>> pending;
};
AudioDecoder::AudioDecoder(std::shared_ptr<AudioBuffer> buffer, std::function<void(const char *)> log)
    : buffer_(std::move(buffer)), log_(std::move(log)) {}
AudioDecoder::~AudioDecoder() = default;
void AudioDecoder::clear() { codec_.reset(); }
bool AudioDecoder::open() {
    if (ct_ == 8) {
        log_("Unsupported Windows audio codec: AAC-ELD (ct=8); the system AAC decoder does not support ELD");
        return false;
    }
    auto candidate = std::make_unique<Codec>();
    if (ct_ == 2) {
        candidate->alac = std::make_unique<AlacDecoder>();
        if (!candidate->alac->open(spf_)) return false;
    } else {
        // Microsoft's AAC MFT explicitly excludes 960-sample AAC-LC frames.
        if (spf_ != 1024) { log_("Unsupported Windows AAC-LC frame length: only 1024 samples are supported"); return false; }
        if (!windows_media_ready() || FAILED(CoCreateInstance(CLSID_CMSAACDecMFT, nullptr, CLSCTX_INPROC_SERVER,
                                                             IID_PPV_ARGS(&candidate->aac)))) {
            log_("Unavailable Windows AAC decoder; Windows N requires the Media Feature Pack"); return false;
        }
        ComPtr<IMFMediaType> input, output;
        if (FAILED(MFCreateMediaType(&input)) || FAILED(MFCreateMediaType(&output))) return false;
        const uint8_t config[] = {0x12, 0x10};
        input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        input->SetGUID(MF_MT_SUBTYPE, MEDIASUBTYPE_RAW_AAC1);
        input->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kSampleRate);
        input->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        input->SetBlob(MF_MT_USER_DATA, config, sizeof(config));
        output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        output->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        output->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kSampleRate);
        output->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
        output->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        output->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
        output->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kSampleRate * 4);
        if (FAILED(candidate->aac->SetInputType(0, input.Get(), 0)) ||
            FAILED(candidate->aac->SetOutputType(0, output.Get(), 0))) return false;
        windows_begin_stream(candidate->aac.Get());
    }
    codec_ = std::move(candidate);
    log_(ct_ == 2 ? "Apple ALAC decoder ready" : "Media Foundation AAC-LC decoder ready");
    return true;
}
bool AudioDecoder::decode_packet(const uint8_t *data, size_t size, int64_t deadline,
                                 uint64_t generation, bool *produced) {
    if (codec_->alac) {
        std::vector<int16_t> pcm;
        if (!codec_->alac->decode(data, size, pcm)) return false;
        write_pcm(pcm.data(), pcm.size() / 2, deadline, generation, produced);
        return true;
    }
    if (!windows_media_ready()) return false;
    auto drain = [&]() {
        for (size_t attempts = 0; attempts < 64; ++attempts) {
            auto owned = windows_output_sample(codec_->aac.Get());
            MFT_OUTPUT_DATA_BUFFER result{}; result.pSample = owned.Get();
            DWORD status = 0;
            const auto hr = codec_->aac->ProcessOutput(0, 1, &result, &status);
            if (result.pEvents) result.pEvents->Release();
            ComPtr<IMFSample> provided;
            if (result.pSample && result.pSample != owned.Get()) provided.Attach(result.pSample);
            if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
            // A dynamic rate/channel change cannot be accepted by AudioBuffer.
            if (FAILED(hr) || !result.pSample || codec_->pending.empty()) return false;
            ComPtr<IMFMediaBuffer> output;
            if (FAILED(result.pSample->ConvertToContiguousBuffer(&output))) return false;
            BYTE *bytes = nullptr; DWORD length = 0;
            if (FAILED(output->Lock(&bytes, nullptr, &length))) return false;
            const auto stamp = codec_->pending.front(); codec_->pending.pop_front();
            const bool valid = length % 4 == 0 && length <= 16384;
            std::vector<int16_t> pcm(length / sizeof(int16_t));
            if (valid && length) std::memcpy(pcm.data(), bytes, length);
            output->Unlock();
            if (!valid) return false;
            if (length) write_pcm(pcm.data(), pcm.size() / 2, stamp.first, stamp.second, produced);
        }
        return false;
    };
    if (!drain() || codec_->pending.size() >= 64) return false;
    auto input = windows_sample(data, size, deadline);
    if (!input) return false;
    input->SetSampleDuration(int64_t(spf_) * 10000000 / kSampleRate);
    if (FAILED(codec_->aac->ProcessInput(0, input.Get(), 0))) return false;
    codec_->pending.emplace_back(deadline, generation);
    return drain();
}
} // namespace airplay
