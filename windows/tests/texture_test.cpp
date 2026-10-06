// SPDX-License-Identifier: GPL-3.0-only
#include "gpu_video_texture.h"
#include <cstdio>
#include <stdexcept>

using Microsoft::WRL::ComPtr;
void check(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
ComPtr<ID3D11Texture2D> make_texture(ID3D11Device *device, UINT width, UINT height) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width; desc.Height = height; desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM; desc.SampleDesc.Count = 1;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    ComPtr<ID3D11Texture2D> texture;
    check(SUCCEEDED(device->CreateTexture2D(&desc, nullptr, &texture)), "Shared texture allocation");
    return texture;
}
int main() {
    try {
        ComPtr<ID3D11Device> device;
        if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, nullptr))) {
            std::puts("SKIP: hardware D3D11 device unavailable"); return 77;
        }
        GpuFrames frames;
        check(!frames.copy(), "Empty host publishes no descriptor");
        auto first = make_texture(device.Get(), 640, 360);
        auto second = make_texture(device.Get(), 360, 640);
        check(frames.receive({nullptr, 640, 360, 0, first.Get()}), "Receive landscape");
        auto *descriptor = frames.copy();
        check(descriptor && descriptor->width == 640 && descriptor->height == 360,
              "Landscape descriptor dimensions");
        auto *stable = descriptor;
        // Replace producer reference between descriptor acquisition and import.
        first.Reset();
        check(frames.receive({nullptr, 360, 640, 0, second.Get()}), "Receive portrait while old import pending");
        ComPtr<ID3D11Texture2D> imported;
        check(SUCCEEDED(device->OpenSharedResource(descriptor->handle, IID_PPV_ARGS(&imported))),
              "Descriptor keeps replaced producer texture alive until import");
        descriptor->release_callback(descriptor->release_context);
        check(descriptor->visible_width == 640 && descriptor->visible_height == 360,
              "Flutter can read dimensions after release callback");
        descriptor = frames.copy();
        check(descriptor == stable && descriptor->width == 360 && descriptor->height == 640,
              "Stable descriptor updates on rotation");
        second.Reset(); frames.clear();
        ComPtr<ID3D11Texture2D> portrait;
        check(SUCCEEDED(device->OpenSharedResource(descriptor->handle, IID_PPV_ARGS(&portrait))),
              "Clear does not invalidate pending import");
        descriptor->release_callback(descriptor->release_context);
        check(descriptor->visible_width == 360 && descriptor->visible_height == 640,
              "Descriptor survives release and clear");
        check(!frames.copy(), "Clear stops publishing textures");
        check(!frames.receive({nullptr, 640, 360, 0, portrait.Get()}), "Reject mismatched dimensions");
        auto next = make_texture(device.Get(), 3840, 2160);
        check(frames.receive({nullptr, 3840, 2160, 0, next.Get()}), "Reconnect with 4K texture");
        descriptor = frames.copy(); descriptor->release_callback(descriptor->release_context);
        check(descriptor->width == 3840 && descriptor->height == 2160, "4K descriptor after release");
        descriptor = frames.copy(); descriptor->release_callback(descriptor->release_context);
        check(frames.receive({nullptr, 640, 360, 0, imported.Get()}), "Receive unacquired frame");
        check(frames.receive({nullptr, 360, 640, 0, portrait.Get()}), "Overwrite unacquired frame");
        descriptor = frames.copy(); descriptor->release_callback(descriptor->release_context);
        check(frames.stats.received == 3 && frames.stats.acquired_new == 2 &&
              frames.stats.overwritten == 1 && frames.stats.repeated == 1,
              "Diagnostics distinguish replaced, newly acquired and repeated textures");
        frames.clear();
        check(frames.stats.received == 0 && frames.stats.last_acquire_ns == 0,
              "Clear resets diagnostics without carrying a reconnect gap");
        std::puts("PASS: Windows Flutter GPU descriptor import, release, rotation, clear and reconnect");
        return 0;
    } catch (const std::exception &error) { std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1; }
}
