// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "windows_media.h"
#include <d3d11.h>
#include <d3d10.h>
#include <dxgi.h>
#include <chrono>
#include <thread>

namespace airplay {
// Decoder and video processor share one device. Published output textures are
// immutable: Flutter's release callback only means "imported", not "presented".
// Rewriting a ring of textures at that point would race the renderer.
class WindowsGpuVideo {
public:
    bool create(IDXGIAdapter *adapter) {
        if (device_) return manager_ && completion_ && SUCCEEDED(device_->GetDeviceRemovedReason());
        if (!windows_media_ready()) return false;
        const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
        auto hr = D3D11CreateDevice(adapter, adapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE,
            nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            levels, 2, D3D11_SDK_VERSION, &device_, nullptr, &context_);
        if (FAILED(hr)) return false;
        ComPtr<ID3D10Multithread> threads;
        if (FAILED(context_.As(&threads))) return false;
        threads->SetMultithreadProtected(TRUE);
        UINT token = 0;
        if (FAILED(device_.As(&video_device_)) || FAILED(context_.As(&video_context_)) ||
            FAILED(MFCreateDXGIDeviceManager(&token, &manager_)) ||
            FAILED(manager_->ResetDevice(device_.Get(), token))) return false;
        D3D11_QUERY_DESC query{D3D11_QUERY_EVENT, 0};
        return SUCCEEDED(device_->CreateQuery(&query, &completion_));
    }
    IMFDXGIDeviceManager *manager() const { return manager_.Get(); }
    ID3D11Device *device() const { return device_.Get(); }
    ID3D11DeviceContext *context() const { return context_.Get(); }
    ComPtr<ID3D11Texture2D> convert(ID3D11Texture2D *input, UINT slice,
        UINT crop_x, UINT crop_y, UINT width, UINT height, bool bt709, bool full_range) {
        if (!input || !device_ || FAILED(device_->GetDeviceRemovedReason())) return {};
        D3D11_TEXTURE2D_DESC source{}; input->GetDesc(&source);
        ComPtr<ID3D11Device> owner; input->GetDevice(&owner);
        if (owner.Get() != device_.Get() || !width || !height || source.MipLevels != 1 || slice >= source.ArraySize ||
            crop_x > source.Width || width > source.Width - crop_x ||
            crop_y > source.Height || height > source.Height - crop_y ||
            (source.Format != DXGI_FORMAT_NV12 && source.Format != DXGI_FORMAT_P010)) return {};
        if (!processor_ || source.Width != input_width_ || source.Height != input_height_ ||
            width != output_width_ || height != output_height_) {
            processor_.Reset(); enumerator_.Reset();
            D3D11_VIDEO_PROCESSOR_CONTENT_DESC content{};
            content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
            content.InputFrameRate = content.OutputFrameRate = {60, 1};
            content.InputWidth = source.Width; content.InputHeight = source.Height;
            content.OutputWidth = width; content.OutputHeight = height;
            content.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
            if (FAILED(video_device_->CreateVideoProcessorEnumerator(&content, &enumerator_)) ||
                FAILED(video_device_->CreateVideoProcessor(enumerator_.Get(), 0, &processor_))) return {};
            input_width_ = source.Width; input_height_ = source.Height;
            output_width_ = width; output_height_ = height;
        }
        UINT support = 0;
        if (FAILED(enumerator_->CheckVideoProcessorFormat(source.Format, &support)) ||
            !(support & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_INPUT) ||
            FAILED(enumerator_->CheckVideoProcessorFormat(DXGI_FORMAT_B8G8R8A8_UNORM, &support)) ||
            !(support & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_OUTPUT)) return {};
        D3D11_TEXTURE2D_DESC target{};
        target.Width = width; target.Height = height; target.MipLevels = target.ArraySize = 1;
        target.Format = DXGI_FORMAT_B8G8R8A8_UNORM; target.SampleDesc.Count = 1;
        target.Usage = D3D11_USAGE_DEFAULT;
        target.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        target.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
        ComPtr<ID3D11Texture2D> output;
        if (FAILED(device_->CreateTexture2D(&target, nullptr, &output))) return {};
        D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC in{};
        in.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
        in.Texture2D.ArraySlice = slice;
        ComPtr<ID3D11VideoProcessorInputView> input_view;
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC out{};
        out.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        ComPtr<ID3D11VideoProcessorOutputView> output_view;
        if (FAILED(video_device_->CreateVideoProcessorInputView(input, enumerator_.Get(), &in, &input_view)) ||
            FAILED(video_device_->CreateVideoProcessorOutputView(output.Get(), enumerator_.Get(), &out, &output_view))) return {};
        RECT src{LONG(crop_x), LONG(crop_y), LONG(crop_x + width), LONG(crop_y + height)};
        RECT dst{0, 0, LONG(width), LONG(height)};
        video_context_->VideoProcessorSetStreamFrameFormat(processor_.Get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
        video_context_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &src);
        video_context_->VideoProcessorSetStreamDestRect(processor_.Get(), 0, TRUE, &dst);
        video_context_->VideoProcessorSetOutputTargetRect(processor_.Get(), TRUE, &dst);
        video_context_->VideoProcessorSetStreamAutoProcessingMode(processor_.Get(), 0, FALSE);
        D3D11_VIDEO_PROCESSOR_COLOR_SPACE input_color{};
        input_color.YCbCr_Matrix = bt709 ? 1 : 0;
        input_color.Nominal_Range = full_range ? D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255
                                             : D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
        D3D11_VIDEO_PROCESSOR_COLOR_SPACE output_color{};
        video_context_->VideoProcessorSetStreamColorSpace(processor_.Get(), 0, &input_color);
        video_context_->VideoProcessorSetOutputColorSpace(processor_.Get(), &output_color);
        video_context_->VideoProcessorSetOutputAlphaFillMode(processor_.Get(), D3D11_VIDEO_PROCESSOR_ALPHA_FILL_MODE_OPAQUE, 0);
        D3D11_VIDEO_PROCESSOR_STREAM stream{};
        stream.Enable = TRUE; stream.pInputSurface = input_view.Get();
        if (FAILED(video_context_->VideoProcessorBlt(processor_.Get(), output_view.Get(), 0, 1, &stream))) return {};
        // Flush alone only submits work. Wait for completion before Flutter's
        // different D3D device reads this shared texture; never wait indefinitely.
        context_->End(completion_.Get()); context_->Flush();
        const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
        HRESULT status;
        while ((status = context_->GetData(completion_.Get(), nullptr, 0, D3D11_ASYNC_GETDATA_DONOTFLUSH)) == S_FALSE) {
            if (std::chrono::steady_clock::now() >= until) return {};
            std::this_thread::yield();
        }
        return SUCCEEDED(status) ? output : ComPtr<ID3D11Texture2D>{};
    }
private:
    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> context_;
    ComPtr<IMFDXGIDeviceManager> manager_;
    ComPtr<ID3D11VideoDevice> video_device_;
    ComPtr<ID3D11VideoContext> video_context_;
    ComPtr<ID3D11VideoProcessorEnumerator> enumerator_;
    ComPtr<ID3D11VideoProcessor> processor_;
    ComPtr<ID3D11Query> completion_;
    UINT input_width_ = 0, input_height_ = 0, output_width_ = 0, output_height_ = 0;
};
} // namespace airplay
