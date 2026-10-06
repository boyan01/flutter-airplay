// SPDX-License-Identifier: GPL-3.0-only
#include "../../playback/platform.h"
#include "windows_media.h"
#include "windows_pixels.h"
#include "windows_video.h"
#include "windows_gpu.h"
#include "../ffmpeg/ffmpeg_video.h"
#include "../../playback/video_scheduler.h"
#include <codecapi.h>
#include <deque>
#include <cstdio>

namespace airplay {
class WindowsVideo final : public VideoOutput {
public:
    explicit WindowsVideo(VideoCallbacks callbacks, const WindowsVideoOptions *options) : callbacks_(std::move(callbacks)),
        ffmpeg_(make_ffmpeg_video_output(callbacks_, options)), hevc_mft_(bool(make_decoder(true))) {
        if (options) { adapter_ = options->adapter; gpu_requested_ = options->gpu; }
    }
    bool supports_hevc() const override { return hevc_mft_ || ffmpeg_->supports_hevc(); }
    ~WindowsVideo() override { reset(); }
    bool can_decode() const override { return using_ffmpeg_ ? ffmpeg_->can_decode() : scheduler_.can_decode(); }
    int64_t next_deadline() const override { return using_ffmpeg_ ? ffmpeg_->next_deadline() : scheduler_.next_deadline(); }
    void size(int, int) override {} // Decode dimensions and orientation come from the SPS.
    void reset() override {
        scheduler_.clear();
        if (decoder_) decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        decoder_.Reset(); pending_.clear(); width_ = height_ = stride_ = 0; gpu_decoder_ = false;
        vps_.clear(); sps_.clear(); pps_.clear();
        ffmpeg_->reset(); using_ffmpeg_ = false; hevc_ = false;
    }
    void drain() override {
        if (using_ffmpeg_) ffmpeg_->drain();
        else {
            if (decoder_ && !output()) {
                if (gpu_decoder_ && gpu_failed_) retire_gpu_decoder();
                else reset();
            }
            report();
            scheduler_.drain();
            const auto schedule = scheduler_.diagnostics();
            if (!schedule.empty() && callbacks_.log) callbacks_.log(schedule.c_str());
        }
    }
    bool decode(const VideoPacket &packet) override {
        const bool accepted = decode_packet(packet);
        if (!accepted && gpu_decoder_ && gpu_failed_) {
            // Shared core treats a failed decode as a terminal receiver error.
            // Handle GPU recovery here, preserving parameter sets until IDR.
            retire_gpu_decoder();
            return true;
        }
        return accepted;
    }
    bool decode_packet(const VideoPacket &packet) {
        if (packet.hevc != hevc_) {
            reset(); hevc_ = packet.hevc;
            using_ffmpeg_ = hevc_ && !hevc_mft_;
        }
        if (using_ffmpeg_) return ffmpeg_->decode(packet);
        scheduler_.begin(packet.generation);
        bool picture = false, keyframe = false, changed = false;
        for (const auto &nal : split_nals(packet.bytes.data(), packet.bytes.size())) {
            if (nal.empty()) continue;
            if (hevc_ && (nal.size() < 2 || (nal[0] & 0x80) || !(nal[1] & 7))) return false;
            const auto type = hevc_ ? (nal[0] >> 1) & 63 : nal[0] & 31;
            if (hevc_ ? type >= 32 && type <= 34 : type == 7 || type == 8) {
                auto &parameter = hevc_ && type == 32 ? vps_ : type == (hevc_ ? 33 : 7) ? sps_ : pps_;
                if (parameter != nal) { parameter = nal; changed = true; }
            }
            picture |= hevc_ ? type <= 31 : type == 1 || type == 5;
            keyframe |= hevc_ ? type >= 16 && type <= 23 : type == 5;
        }
        if (changed && decoder_) {
            scheduler_.clear(); scheduler_.begin(packet.generation);
            decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
            decoder_.Reset(); pending_.clear();
        }
        if (!picture) return true;
        std::vector<uint8_t> input_bytes;
        if (!decoder_) {
            if (!keyframe || sps_.empty() || pps_.empty() || (hevc_ && vps_.empty())) return true;
            // Parameter sets may have arrived separately before the first IDR.
            for (const auto *parameter : {&vps_, &sps_, &pps_}) {
                if (parameter->empty()) continue;
                input_bytes.insert(input_bytes.end(), {0, 0, 0, 1});
                input_bytes.insert(input_bytes.end(), parameter->begin(), parameter->end());
            }
            if (!open()) {
                if (!hevc_ || !ffmpeg_->supports_hevc()) return false;
                decoder_.Reset(); pending_.clear(); using_ffmpeg_ = true;
                callbacks_.log("Windows HEVC MFT unavailable for this stream; trying bundled FFmpeg decoding");
                auto fallback = packet;
                fallback.bytes = std::move(input_bytes);
                fallback.bytes.insert(fallback.bytes.end(), packet.bytes.begin(), packet.bytes.end());
                return ffmpeg_->decode(fallback);
            }
        }
        input_bytes.insert(input_bytes.end(), packet.bytes.begin(), packet.bytes.end());
        if (!output() || pending_.size() >= 128) return false;
        auto sample = windows_sample(input_bytes.data(), input_bytes.size(), packet.deadline);
        if (!sample) return false;
        sample->SetSampleDuration(10000000 / 60);
        const auto hr = decoder_->ProcessInput(0, sample.Get(), 0);
        if (FAILED(hr)) { if (gpu_decoder_) disable_gpu(); return false; }
        pending_.push_back({packet.deadline, packet.generation});
        return output();
    }
private:
    static ComPtr<IMFTransform> make_decoder(bool hevc) {
        ComPtr<IMFTransform> result;
        if (!windows_media_ready()) return result;
        if (!hevc) {
            CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&result));
            return result;
        }
        MFT_REGISTER_TYPE_INFO input{MFMediaType_Video, MFVideoFormat_HEVC};
        IMFActivate **activations = nullptr;
        UINT32 count = 0;
        if (FAILED(MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
            MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
            &input, nullptr, &activations, &count))) return result;
        for (UINT32 i = 0; i < count; ++i) {
            if (!result) activations[i]->ActivateObject(IID_PPV_ARGS(&result));
            activations[i]->Release();
        }
        CoTaskMemFree(activations);
        return result;
    }
    bool open() {
        if (gpu_requested_ && !gpu_failed_ && gpu_.create(adapter_.Get())) {
            if (open_decoder(true)) return true;
            callbacks_.log("Windows D3D11 decoder negotiation failed; retrying CPU decoding");
        }
        return open_decoder(false);
    }
    bool open_decoder(bool gpu) {
        gpu_decoder_ = false;
        decoder_ = make_decoder(hevc_);
        if (!decoder_) {
            callbacks_.log(hevc_ ? "Unavailable Windows HEVC MFT" : "Unavailable Windows H.264 decoder; Windows N requires the Media Feature Pack"); return false;
        }
        ComPtr<IMFAttributes> attributes;
        if (SUCCEEDED(decoder_->GetAttributes(&attributes))) attributes->SetUINT32(CODECAPI_AVLowLatencyMode, TRUE);
        if (gpu && (!attributes || !MFGetAttributeUINT32(attributes.Get(), MF_SA_D3D11_AWARE, FALSE) ||
            FAILED(decoder_->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, reinterpret_cast<ULONG_PTR>(gpu_.manager()))))) return false;
        ComPtr<IMFMediaType> input;
        if (FAILED(MFCreateMediaType(&input))) return false;
        input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        input->SetGUID(MF_MT_SUBTYPE, hevc_ ? MFVideoFormat_HEVC : MFVideoFormat_H264);
        if (hevc_ && sps_.size() >= 4) {
            // The general profile_idc follows the SPS sublayer header.
            const auto profile = sps_[3] & 31;
            if (profile == 1 || profile == 2) input->SetUINT32(MF_MT_MPEG2_PROFILE, profile);
        }
        input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_MixedInterlaceOrProgressive);
        if (FAILED(decoder_->SetInputType(0, input.Get(), 0)) || !select_output()) return false;
        windows_begin_stream(decoder_.Get());
        gpu_decoder_ = gpu;
        callbacks_.log(gpu ? "Windows D3D11 decoder ready; GPU color conversion and Flutter shared texture enabled"
                            : hevc_ ? "Media Foundation HEVC decoder ready; NV12/P010 converted to Flutter RGBA pixels"
                            : "Media Foundation H.264 decoder ready; NV12 converted to Flutter RGBA pixels");
        return true;
    }
    bool select_output() {
        for (DWORD index = 0; index < 64; ++index) {
            ComPtr<IMFMediaType> type;
            if (FAILED(decoder_->GetOutputAvailableType(0, index, &type))) break;
            GUID subtype{};
            if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) ||
                (subtype != MFVideoFormat_NV12 && (!hevc_ || subtype != MFVideoFormat_P010))) continue;
            if (FAILED(decoder_->SetOutputType(0, type.Get(), 0))) continue;
            p010_ = subtype == MFVideoFormat_P010;
            UINT32 width = 0, height = 0;
            if (FAILED(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width, &height))) return false;
            width_ = width; height_ = height;
            const auto stride = MFGetAttributeUINT32(type.Get(), MF_MT_DEFAULT_STRIDE, width * (p010_ ? 2 : 1));
            if (stride > 32768) return false;
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
            if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
                if (!select_output()) { if (gpu_decoder_) disable_gpu(); return false; }
                continue;
            }
            if (FAILED(hr) || !result.pSample || pending_.empty()) {
                if (gpu_decoder_) disable_gpu();
                return false;
            }
            LONGLONG time = 0;
            auto pending = pending_.begin();
            if (SUCCEEDED(result.pSample->GetSampleTime(&time))) {
                auto match = std::find_if(pending_.begin(), pending_.end(), [&](const Stamp &s) { return s.deadline / 100 == time; });
                if (match != pending_.end()) pending = match;
            }
            const auto stamp = *pending; pending_.erase(pending);
            ++decoded_;
            // Keep decoding reference pictures, but avoid copying/converting
            // frames the shared presentation callback would already discard.
            // This lets a 4K stream catch up after a short output stall.
            if (stamp.deadline < monotonic_ns() - kVideoLateToleranceNs) { ++late_; continue; }
            const auto conversion_start = monotonic_ns();
            ComPtr<IMFMediaBuffer> buffer;
            if (gpu_decoder_ && SUCCEEDED(result.pSample->GetBufferByIndex(0, &buffer))) {
                ComPtr<IMFDXGIBuffer> dxgi;
                ComPtr<ID3D11Texture2D> source;
                UINT slice = 0;
                if (SUCCEEDED(buffer.As(&dxgi)) && SUCCEEDED(dxgi->GetResource(IID_PPV_ARGS(&source))) &&
                    SUCCEEDED(dxgi->GetSubresourceIndex(&slice))) {
                    auto texture = gpu_.convert(source.Get(), slice, UINT(crop_x_), UINT(crop_y_),
                        UINT(display_width_), UINT(display_height_), bt709_, full_range_);
                    if (texture) {
                        const auto cost = monotonic_ns() - conversion_start;
                        ++gpu_frames_; gpu_ns_ += cost; gpu_max_ns_ = std::max(gpu_max_ns_, cost);
                        const auto w = display_width_, h = display_height_;
                        scheduler_.enqueue(stamp.deadline, stamp.generation,
                            [this, texture, w, h, stamp](bool show) {
                                WindowsVideoFrame frame{nullptr, w, h, 0, texture.Get()};
                                if (show && callbacks_.frame) callbacks_.frame(&frame, int(w), int(h), stamp.deadline, stamp.generation);
                            });
                        continue;
                    }
                    // Retire the decoder and renegotiate in CPU mode at the
                    // next keyframe; never publish a half-written GPU surface.
                    disable_gpu(); return false;
                }
            }
            if (FAILED(result.pSample->ConvertToContiguousBuffer(&buffer))) return false;
            ComPtr<IMF2DBuffer> plane;
            bool converted = false;
            if (SUCCEEDED(buffer.As(&plane))) {
                DWORD length = 0;
                if (FAILED(plane->GetContiguousLength(&length)) || length > 128 * 1024 * 1024) return false;
                nv12_.resize(length);
                if (FAILED(plane->ContiguousCopyTo(nv12_.data(), length))) return false;
                converted = windows_yuv420_to_rgba(nv12_.data(), length, width_, height_, width_ * (p010_ ? 2 : 1), bt709_, full_range_, rgba_, p010_);
            } else {
                BYTE *bytes = nullptr; DWORD length = 0;
                if (FAILED(buffer->Lock(&bytes, nullptr, &length))) return false;
                converted = windows_yuv420_to_rgba(bytes, length, width_, height_, stride_, bt709_, full_range_, rgba_, p010_);
                buffer->Unlock();
            }
            if (!converted) return false;
            const auto cost = monotonic_ns() - conversion_start;
            ++converted_; conversion_ns_ += cost; conversion_max_ns_ = std::max(conversion_max_ns_, cost);
            auto pixels = std::make_shared<std::vector<uint8_t>>(std::move(rgba_));
            const auto offset = (crop_y_ * width_ + crop_x_) * 4;
            const auto w = display_width_, h = display_height_, stride = width_ * 4;
            scheduler_.enqueue(stamp.deadline, stamp.generation,
                [this, pixels, offset, w, h, stride, stamp](bool show) {
                    WindowsVideoFrame frame{pixels->data() + offset, w, h, stride};
                    if (show && callbacks_.frame) callbacks_.frame(&frame, int(w), int(h), stamp.deadline, stamp.generation);
                });
        }
        return false;
    }
    void disable_gpu() {
        gpu_failed_ = true;
        callbacks_.log("Windows D3D11 output failed; recovering with CPU decoding at the next keyframe");
    }
    void retire_gpu_decoder() {
        scheduler_.clear();
        decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        decoder_.Reset(); pending_.clear(); gpu_decoder_ = false;
    }
    void report() {
        const auto now = monotonic_ns();
        if (now < next_report_) return;
        next_report_ = now + 5 * kSecond;
        if (!decoded_ || !callbacks_.log) return;
        char message[384];
        std::snprintf(message, sizeof(message),
            "Windows video output: decoded_total=%llu converted_total=%llu late_before_convert_total=%llu conversion_avg_ms=%.2f conversion_max_ms=%.2f size=%zux%zu gpu_total=%llu gpu_avg_ms=%.2f gpu_max_ms=%.2f",
            static_cast<unsigned long long>(decoded_), static_cast<unsigned long long>(converted_),
            static_cast<unsigned long long>(late_), converted_ ? double(conversion_ns_) / converted_ / 1000000 : 0,
            double(conversion_max_ns_) / 1000000, display_width_, display_height_,
            static_cast<unsigned long long>(gpu_frames_), gpu_frames_ ? double(gpu_ns_) / gpu_frames_ / 1000000 : 0,
            double(gpu_max_ns_) / 1000000);
        callbacks_.log(message);
    }
    uint64_t decoded_ = 0, converted_ = 0, late_ = 0;
    int64_t conversion_ns_ = 0, conversion_max_ns_ = 0, next_report_ = monotonic_ns() + 5 * kSecond;
    uint64_t gpu_frames_ = 0;
    int64_t gpu_ns_ = 0, gpu_max_ns_ = 0;
    WindowsGpuVideo gpu_;
    ComPtr<IDXGIAdapter> adapter_;
    bool gpu_requested_ = false, gpu_failed_ = false, gpu_decoder_ = false;
    struct Stamp { int64_t deadline; uint64_t generation; };
    VideoCallbacks callbacks_;
    VideoScheduler scheduler_;
    std::unique_ptr<VideoOutput> ffmpeg_;
    const bool hevc_mft_;
    ComPtr<IMFTransform> decoder_;
    std::deque<Stamp> pending_;
    std::vector<uint8_t> vps_, sps_, pps_, nv12_, rgba_;
    size_t width_ = 0, height_ = 0, stride_ = 0;
    size_t display_width_ = 0, display_height_ = 0, crop_x_ = 0, crop_y_ = 0;
    bool bt709_ = true, full_range_ = false;
    bool hevc_ = false, using_ffmpeg_ = false, p010_ = false;
};
std::unique_ptr<VideoOutput> make_video_output(void *options, const char *, const char *, VideoCallbacks callbacks) {
    return std::make_unique<WindowsVideo>(std::move(callbacks), static_cast<const WindowsVideoOptions *>(options));
}
} // namespace airplay
