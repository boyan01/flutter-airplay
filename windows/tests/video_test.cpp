// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "ffmpeg_video.h"
#include "windows_video.h"
#include "windows_gpu.h"
#include "video_fixtures.h"
#include "hevc_fixtures.h"
#include "ffmpeg_colors_test.h"
#include "video_scheduler_test.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <thread>

using namespace airplay;

namespace {
void check(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
struct Frame {
    int width, height;
    int64_t deadline;
    uint64_t generation;
    std::array<uint8_t, 4> pixel;
};
std::array<uint8_t, 4> gpu_pixel(ID3D11Texture2D *texture, UINT x, UINT y) {
    ComPtr<ID3D11Device> device; texture->GetDevice(&device);
    ComPtr<ID3D11DeviceContext> context; device->GetImmediateContext(&context);
    D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
    check(desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM, "GPU publishes BGRA");
    desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = desc.MiscFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    check(SUCCEEDED(device->CreateTexture2D(&desc, nullptr, &staging)), "GPU staging texture");
    context->CopyResource(staging.Get(), texture);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    check(SUCCEEDED(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped)), "GPU test readback");
    const auto *pixel = static_cast<const uint8_t *>(mapped.pData) + y * mapped.RowPitch + x * 4;
    std::array<uint8_t, 4> rgba{pixel[2], pixel[1], pixel[0], pixel[3]};
    context->Unmap(staging.Get(), 0); return rgba;
}
bool gpu_conversion() {
    WindowsGpuVideo gpu;
    if (!gpu.create(nullptr)) { std::puts("SKIP: D3D11 video device unavailable"); return false; }
    ComPtr<IDXGIDevice> dxgi; ComPtr<IDXGIAdapter> adapter;
    check(SUCCEEDED(gpu.device()->QueryInterface(IID_PPV_ARGS(&dxgi))) &&
          SUCCEEDED(dxgi->GetAdapter(&adapter)), "GPU adapter");
    ComPtr<ID3D11Device> consumer;
    check(SUCCEEDED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &consumer, nullptr, nullptr)),
        "Different consumer device on Flutter's adapter");
    for (bool p010 : {false, true}) for (bool full : {false, true}) for (bool bt709 : {false, true}) {
        constexpr UINT width = 64, height = 32;
        const UINT stride = width * (p010 ? 2 : 1);
        std::vector<uint8_t> bytes(stride * height * 3 / 2);
        auto set = [&](size_t offset, uint8_t value) {
            if (p010) { bytes[offset * 2] = 0; bytes[offset * 2 + 1] = value; }
            else bytes[offset] = value;
        };
        // Two neutral brightness regions exercise cropping and range mapping.
        for (UINT y = 0; y < height; ++y) for (UINT x = 0; x < width; ++x)
            set(y * width + x, x < 32 ? (full ? 0 : 16) : (full ? 255 : 235));
        for (size_t i = width * height; i < width * height * 3 / 2; ++i) set(i, 128);
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = width; desc.Height = height; desc.MipLevels = desc.ArraySize = 1;
        desc.Format = p010 ? DXGI_FORMAT_P010 : DXGI_FORMAT_NV12;
        desc.SampleDesc.Count = 1; desc.BindFlags = D3D11_BIND_DECODER;
        D3D11_SUBRESOURCE_DATA data{bytes.data(), stride, 0};
        ComPtr<ID3D11Texture2D> input;
        check(SUCCEEDED(gpu.device()->CreateTexture2D(&desc, &data, &input)), "Synthetic GPU NV12/P010");
        auto white = gpu.convert(input.Get(), 0, 32, 0, 32, 32, bt709, full);
        check(bool(white), "GPU converts/crops NV12/P010");
        auto color = gpu_pixel(white.Get(), 16, 16);
        check(color[0] > 245 && color[1] > 245 && color[2] > 245 && color[3] == 255,
              "GPU range/crop produces opaque white");
        auto black = gpu.convert(input.Get(), 0, 0, 0, 32, 32, bt709, full);
        check(bool(black), "GPU converts another immutable output");
        color = gpu_pixel(black.Get(), 16, 16);
        check(color[0] < 10 && color[1] < 10 && color[2] < 10 && color[3] == 255, "GPU black level");
        check(gpu_pixel(white.Get(), 16, 16)[0] > 245, "Published GPU frame survives later conversion");
        ComPtr<IDXGIResource> resource; HANDLE shared = nullptr;
        check(SUCCEEDED(white.As(&resource)) && SUCCEEDED(resource->GetSharedHandle(&shared)) && shared,
              "GPU output has a Flutter shared handle");
        ComPtr<ID3D11Texture2D> imported;
        check(SUCCEEDED(consumer->OpenSharedResource(shared, IID_PPV_ARGS(&imported))), "Consumer imports GPU frame");
        white.Reset();
        check(gpu_pixel(imported.Get(), 16, 16)[0] > 245, "Imported frame outlives producer reference");
        check(!gpu.convert(input.Get(), 1, 0, 0, 32, 32, bt709, full), "GPU rejects invalid array slice");
        check(!gpu.convert(input.Get(), 0, 40, 0, 32, 32, bt709, full), "GPU rejects out-of-bounds crop");
    }
    std::puts("PASS: GPU NV12/P010 conversion, range, crop, alpha, immutable/shared frames");
    ComPtr<ID3D11VideoDevice> video;
    UINT configs = 0;
    D3D11_VIDEO_DECODER_DESC hevc{D3D11_DECODER_PROFILE_HEVC_VLD_MAIN, 640, 360, DXGI_FORMAT_NV12};
    return SUCCEEDED(gpu.device()->QueryInterface(IID_PPV_ARGS(&video))) &&
        SUCCEEDED(video->GetVideoDecoderConfigCount(&hevc, &configs)) && configs > 0;
}
} // namespace

int main(int argc, char **argv) {
    try {
        const bool software = argc == 2 && std::strcmp(argv[1], "--software") == 0;
        if (software) airplay_test::ffmpeg_colors_test();
        const bool gpu = argc == 2 && std::strcmp(argv[1], "--gpu") == 0;
        check(argc == 1 || software || gpu, "Usage: windows_video_test [--software|--gpu]");
        if (argc == 1) airplay_test::video_scheduler_test();
        const bool expect_hevc_gpu = gpu && gpu_conversion();
        std::vector<Frame> frames;
        size_t gpu_frames = 0;
        VideoCallbacks callbacks{
            [&](void *pointer, int width, int height, int64_t deadline, uint64_t generation) {
                const auto *image = static_cast<const WindowsVideoFrame *>(pointer);
                check(image && (image->pixels || image->texture) && image->width == size_t(width) &&
                      image->height == size_t(height), "Windows callback borrows valid pixels/texture");
                Frame frame{width, height, deadline, generation, {}};
                if (image->texture) {
                    frame.pixel = gpu_pixel(image->texture, width / 2, height / 2); ++gpu_frames;
                }
                else {
                    check(image->stride >= size_t(width) * 4, "CPU RGBA stride");
                    std::copy_n(image->pixels + size_t(height / 2) * image->stride + (width / 2) * 4,
                                4, frame.pixel.begin());
                }
                frames.push_back(frame);
            }, [](const char *message) { std::puts(message); }
        };
        WindowsVideoOptions options{nullptr, gpu};
        auto video = software ? make_ffmpeg_video_output(callbacks)
                              : make_video_output(&options, nullptr, nullptr, callbacks);
        check(video->supports_hevc(), "Windows advertises a usable HEVC decoder");
        int64_t anchor = monotonic_ns() + kSecond;
        auto feed = [&](const uint8_t *data, size_t size, int width, int height, int channel, bool hevc) {
            const auto before = frames.size();
            constexpr int64_t tick = 16666667;
            for (int i = 0; i < 4; ++i)
                check(video->decode({{data, data + size}, anchor + i * tick, 77, 0, hevc}),
                      "Windows accepts the synthetic video access unit");
            check(frames.size() == before, "Decoding future pictures returns without waiting or publishing");
            check(video->next_deadline() && video->next_deadline() <= anchor,
                  "Completed output wakes the worker before its display deadline");
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (frames.size() == before && std::chrono::steady_clock::now() < until) {
                video->drain();
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            check(frames.size() > before, "Windows decoder publishes video pixels");
            for (size_t i = before; i < frames.size(); ++i) {
                const auto &frame = frames[i];
                check(frame.width == width && frame.height == height, "Windows source dimensions survive rotation");
                check(frame.generation == 77 && frame.deadline >= anchor &&
                      frame.deadline <= anchor + 3 * tick && (frame.deadline - anchor) % tick == 0,
                      "Windows output keeps originating packet timing and generation");
                check(frame.pixel[channel] > 200 && frame.pixel[(channel + 1) % 3] < 45 &&
                      frame.pixel[(channel + 2) % 3] < 45 && frame.pixel[3] == 255,
                      "Windows decoded RGBA pixels match the fixture color");
            }
            anchor += 1000000000;
        };
        feed(hevc_fixtures::landscape, sizeof(hevc_fixtures::landscape), 640, 360, 0, true);
        if (expect_hevc_gpu) check(gpu_frames > 0, "HEVC uses shared GPU textures when the driver supports Main decoding");
        feed(hevc_fixtures::portrait, sizeof(hevc_fixtures::portrait), 360, 640, 2, true);
        video->reset();
        feed(hevc_fixtures::uhd, sizeof(hevc_fixtures::uhd), 3840, 2160, 2, true);
        feed(hevc_fixtures::main10, sizeof(hevc_fixtures::main10), 640, 360, 1, true);
        check(!video->decode({{0, 0, 1, 0x40}, anchor, 77, 0, true}), "Windows rejects truncated HEVC headers");
        video->reset();
        feed(hevc_fixtures::landscape, sizeof(hevc_fixtures::landscape), 640, 360, 0, true);
        if (!software) feed(landscape, sizeof(landscape), 640, 360, 0, false);
        if (!software) {
            video->reset();
            const auto before = frames.size();
            for (int i = 0; i < 4; ++i)
                check(video->decode({{std::begin(landscape), std::end(landscape)},
                    monotonic_ns() + 2 * kSecond, 88}), "Windows retains future native output");
            check(frames.size() == before, "Held pictures are not submitted immediately");
            video->reset(); video->drain();
            check(frames.size() == before && !video->next_deadline(), "Reset discards held GPU/CPU pictures");
            for (int i = 0; i < 4; ++i)
                check(video->decode({{std::begin(landscape), std::end(landscape)},
                    monotonic_ns() - kSecond, 77}), "Windows decodes late reference pictures");
            video->drain();
            check(frames.size() == before, "Windows avoids converting/publishing expired pictures");
            anchor = monotonic_ns() + kSecond;
            feed(landscape, sizeof(landscape), 640, 360, 0, false);
        }
        std::puts("PASS: Windows HEVC RGBA landscape/portrait/4K/Main10, timing/generation, malformed recovery and reset");
        if (gpu) std::printf("GPU decoded/published frames: %zu (CPU fallback allowed for unsupported codecs)\n", gpu_frames);
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        return 1;
    }
}
