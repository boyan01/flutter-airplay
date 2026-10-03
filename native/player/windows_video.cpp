// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "windows_media.h"
#include "windows_pixels.h"
#include "windows_video.h"
#include <codecapi.h>
#include <deque>

namespace airplay {
class WindowsVideo final : public VideoOutput {
public:
    explicit WindowsVideo(VideoCallbacks callbacks) : callbacks_(std::move(callbacks)) {}
    void size(int, int) override {} // Decode dimensions and orientation come from the SPS.
    void reset() override {
        if (decoder_) decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        decoder_.Reset(); pending_.clear(); width_ = height_ = stride_ = 0;
        sps_.clear(); pps_.clear();
    }
    void drain() override { if (decoder_ && !output()) reset(); }
    bool decode(const VideoPacket &packet) override {
        bool picture = false, keyframe = false, changed = false;
        for (const auto &nal : split_nals(packet.bytes.data(), packet.bytes.size())) {
            if (nal.empty()) continue;
            const auto type = nal[0] & 31;
            if (type == 7 || type == 8) {
                auto &parameter = type == 7 ? sps_ : pps_;
                if (parameter != nal) { parameter = nal; changed = true; }
            }
            picture |= type == 1 || type == 5; keyframe |= type == 5;
        }
        if (changed && decoder_) {
            decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
            decoder_.Reset(); pending_.clear();
        }
        if (!picture) return true;
        std::vector<uint8_t> input_bytes;
        if (!decoder_) {
            if (!keyframe || sps_.empty() || pps_.empty()) return true;
            if (!open()) return false;
            // Parameter sets may have arrived separately before the first IDR.
            for (const auto *parameter : {&sps_, &pps_}) {
                input_bytes.insert(input_bytes.end(), {0, 0, 0, 1});
                input_bytes.insert(input_bytes.end(), parameter->begin(), parameter->end());
            }
        }
        input_bytes.insert(input_bytes.end(), packet.bytes.begin(), packet.bytes.end());
        if (!output() || pending_.size() >= 128) return false;
        auto sample = windows_sample(input_bytes.data(), input_bytes.size(), packet.deadline);
        if (!sample) return false;
        sample->SetSampleDuration(10000000 / 60);
        const auto hr = decoder_->ProcessInput(0, sample.Get(), 0);
        if (FAILED(hr)) return false;
        pending_.push_back({packet.deadline, packet.generation});
        return output();
    }
private:
    bool open() {
        if (!windows_media_ready() || FAILED(CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr,
            CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&decoder_)))) {
            callbacks_.log("Unavailable Windows H.264 decoder; Windows N requires the Media Feature Pack"); return false;
        }
        ComPtr<IMFAttributes> attributes;
        if (SUCCEEDED(decoder_->GetAttributes(&attributes))) attributes->SetUINT32(CODECAPI_AVLowLatencyMode, TRUE);
        ComPtr<IMFMediaType> input;
        if (FAILED(MFCreateMediaType(&input))) return false;
        input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
        input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_MixedInterlaceOrProgressive);
        if (FAILED(decoder_->SetInputType(0, input.Get(), 0)) || !select_output()) return false;
        windows_begin_stream(decoder_.Get());
        callbacks_.log("Media Foundation H.264 decoder ready; NV12 converted to Flutter RGBA pixels");
        return true;
    }
    bool select_output() {
        for (DWORD index = 0; index < 64; ++index) {
            ComPtr<IMFMediaType> type;
            if (FAILED(decoder_->GetOutputAvailableType(0, index, &type))) break;
            GUID subtype{};
            if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) || subtype != MFVideoFormat_NV12) continue;
            if (FAILED(decoder_->SetOutputType(0, type.Get(), 0))) continue;
            UINT32 width = 0, height = 0;
            if (FAILED(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width, &height))) return false;
            width_ = width; height_ = height;
            const auto stride = MFGetAttributeUINT32(type.Get(), MF_MT_DEFAULT_STRIDE, width);
            if (stride > 16384) return false;
            stride_ = stride;
            display_width_ = width_; display_height_ = height_; crop_x_ = crop_y_ = 0;
            MFVideoArea aperture{}; UINT32 aperture_bytes = 0;
            if (SUCCEEDED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE,
                reinterpret_cast<UINT8 *>(&aperture), sizeof(aperture), &aperture_bytes)) &&
                aperture_bytes == sizeof(aperture) && aperture.OffsetX.value >= 0 && aperture.OffsetY.value >= 0 &&
                aperture.Area.cx > 0 && aperture.Area.cy > 0 &&
                size_t(aperture.OffsetX.value) + size_t(aperture.Area.cx) <= width_ &&
                size_t(aperture.OffsetY.value) + size_t(aperture.Area.cy) <= height_) {
                crop_x_ = aperture.OffsetX.value; crop_y_ = aperture.OffsetY.value;
                display_width_ = aperture.Area.cx; display_height_ = aperture.Area.cy;
            }
            const auto matrix = MFGetAttributeUINT32(type.Get(), MF_MT_YUV_MATRIX,
                height > 576 ? MFVideoTransferMatrix_BT709 : MFVideoTransferMatrix_BT601);
            bt709_ = matrix == MFVideoTransferMatrix_BT709;
            full_range_ = MFGetAttributeUINT32(type.Get(), MF_MT_VIDEO_NOMINAL_RANGE,
                MFNominalRange_16_235) == MFNominalRange_0_255;
            return width > 0 && height > 0 && width <= 4096 && height <= 4096;
        }
        return false;
    }
    bool output() {
        for (size_t attempt = 0; attempt < 128; ++attempt) {
            auto sample = windows_output_sample(decoder_.Get());
            MFT_OUTPUT_DATA_BUFFER result{}; result.pSample = sample.Get();
            DWORD status = 0;
            const auto hr = decoder_->ProcessOutput(0, 1, &result, &status);
            if (result.pEvents) result.pEvents->Release();
            ComPtr<IMFSample> provided;
            if (result.pSample && result.pSample != sample.Get()) provided.Attach(result.pSample);
            if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
            if (hr == MF_E_TRANSFORM_STREAM_CHANGE) { if (!select_output()) return false; continue; }
            if (FAILED(hr) || !result.pSample || pending_.empty()) return false;
            LONGLONG time = 0;
            auto pending = pending_.begin();
            if (SUCCEEDED(result.pSample->GetSampleTime(&time))) {
                auto match = std::find_if(pending_.begin(), pending_.end(), [&](const Stamp &s) { return s.deadline / 100 == time; });
                if (match != pending_.end()) pending = match;
            }
            const auto stamp = *pending; pending_.erase(pending);
            ComPtr<IMFMediaBuffer> buffer;
            if (FAILED(result.pSample->ConvertToContiguousBuffer(&buffer))) return false;
            ComPtr<IMF2DBuffer> plane;
            bool converted = false;
            if (SUCCEEDED(buffer.As(&plane))) {
                DWORD length = 0;
                if (FAILED(plane->GetContiguousLength(&length)) || length > 128 * 1024 * 1024) return false;
                nv12_.resize(length);
                if (FAILED(plane->ContiguousCopyTo(nv12_.data(), length))) return false;
                converted = windows_nv12_to_rgba(nv12_.data(), length, width_, height_, width_, bt709_, full_range_, rgba_);
            } else {
                BYTE *bytes = nullptr; DWORD length = 0;
                if (FAILED(buffer->Lock(&bytes, nullptr, &length))) return false;
                converted = windows_nv12_to_rgba(bytes, length, width_, height_, stride_, bt709_, full_range_, rgba_);
                buffer->Unlock();
            }
            if (!converted) return false;
            WindowsVideoFrame frame{rgba_.data() + (crop_y_ * width_ + crop_x_) * 4,
                                    display_width_, display_height_, width_ * 4};
            callbacks_.frame(&frame, static_cast<int>(display_width_), static_cast<int>(display_height_), stamp.deadline, stamp.generation);
        }
        return false;
    }
    struct Stamp { int64_t deadline; uint64_t generation; };
    VideoCallbacks callbacks_;
    ComPtr<IMFTransform> decoder_;
    std::deque<Stamp> pending_;
    std::vector<uint8_t> sps_, pps_, nv12_, rgba_;
    size_t width_ = 0, height_ = 0, stride_ = 0;
    size_t display_width_ = 0, display_height_ = 0, crop_x_ = 0, crop_y_ = 0;
    bool bt709_ = true, full_range_ = false;
};
std::unique_ptr<VideoOutput> make_video_output(void *, const char *, const char *, VideoCallbacks callbacks) {
    return std::make_unique<WindowsVideo>(std::move(callbacks));
}
} // namespace airplay
