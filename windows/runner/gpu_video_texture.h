// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "windows_video.h"
#include <flutter/texture_registrar.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <memory>
#include <mutex>

struct GpuFrames {
    std::mutex lock;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> frame;
    HANDLE handle = nullptr;
    size_t width = 0, height = 0;
    // Flutter reads visible dimensions after invoking release_callback. Keep
    // the descriptor alive for the registrar lifetime; release only the COM
    // lease once the engine has imported its resource. Callback access to this
    // descriptor is serialized on this engine's raster thread.
    FlutterDesktopGpuSurfaceDescriptor descriptor{};
    Microsoft::WRL::ComPtr<ID3D11Texture2D> imported_frame;
    bool receive(const airplay::WindowsVideoFrame &input) {
        Microsoft::WRL::ComPtr<IDXGIResource> resource;
        HANDLE shared = nullptr;
        if (!input.texture || !input.width || !input.height || input.width > 4096 || input.height > 4096) return false;
        D3D11_TEXTURE2D_DESC desc{}; input.texture->GetDesc(&desc);
        if (desc.Width != input.width || desc.Height != input.height || desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
            FAILED(input.texture->QueryInterface(IID_PPV_ARGS(&resource))) ||
            FAILED(resource->GetSharedHandle(&shared)) || !shared) return false;
        std::lock_guard<std::mutex> guard(lock);
        frame = input.texture; handle = shared; width = input.width; height = input.height;
        return true;
    }
    void clear() {
        std::lock_guard<std::mutex> guard(lock); frame.Reset(); handle = nullptr;
    }
    const FlutterDesktopGpuSurfaceDescriptor *copy() {
        std::lock_guard<std::mutex> guard(lock);
        if (!frame) return nullptr;
        imported_frame = frame;
        descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
        descriptor.handle = handle;
        descriptor.width = descriptor.visible_width = width;
        descriptor.height = descriptor.visible_height = height;
        descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
        descriptor.release_context = this;
        descriptor.release_callback = [](void *value) {
            auto *state = static_cast<GpuFrames *>(value);
            std::lock_guard<std::mutex> guard(state->lock); state->imported_frame.Reset();
        };
        return &descriptor;
    }
};
