// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "windows_video.h"
#include "timing_stats.h"
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
    struct Stats {
        uint64_t received = 0, acquired_new = 0, overwritten = 0, repeated = 0;
        airplay::TimingSamples acquire_gap, frame_age, lease_hold;
    } stats;
    uint64_t sequence = 0, acquired_sequence = 0;
    int64_t received_ns = 0, last_acquire_ns = 0, lease_started_ns = 0, stats_started_ns = 0;
    bool receive(const airplay::WindowsVideoFrame &input) {
        Microsoft::WRL::ComPtr<IDXGIResource> resource;
        HANDLE shared = nullptr;
        if (!input.texture || !input.width || !input.height || input.width > 4096 || input.height > 4096) return false;
        D3D11_TEXTURE2D_DESC desc{}; input.texture->GetDesc(&desc);
        if (desc.Width != input.width || desc.Height != input.height || desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
            FAILED(input.texture->QueryInterface(IID_PPV_ARGS(&resource))) ||
            FAILED(resource->GetSharedHandle(&shared)) || !shared) return false;
        std::lock_guard<std::mutex> guard(lock);
        const auto now = airplay::TimingSamples::now_ns();
        if (!stats_started_ns) stats_started_ns = now;
        if (frame && sequence != acquired_sequence) ++stats.overwritten;
        ++sequence; ++stats.received; received_ns = now;
        frame = input.texture; handle = shared; width = input.width; height = input.height;
        return true;
    }
    void clear() {
        std::lock_guard<std::mutex> guard(lock); frame.Reset(); handle = nullptr;
        stats = {}; stats_started_ns = last_acquire_ns = received_ns = 0;
        lease_started_ns = 0;
        acquired_sequence = sequence;
    }
    const FlutterDesktopGpuSurfaceDescriptor *copy() {
        std::lock_guard<std::mutex> guard(lock);
        if (!frame) return nullptr;
        const auto now = airplay::TimingSamples::now_ns();
        if (sequence != acquired_sequence) {
            ++stats.acquired_new;
            if (last_acquire_ns) stats.acquire_gap.add(now - last_acquire_ns);
            stats.frame_age.add(now - received_ns);
            acquired_sequence = sequence; last_acquire_ns = now;
        } else ++stats.repeated;
        lease_started_ns = now;
        imported_frame = frame;
        descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
        descriptor.handle = handle;
        descriptor.width = descriptor.visible_width = width;
        descriptor.height = descriptor.visible_height = height;
        descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
        descriptor.release_context = this;
        descriptor.release_callback = [](void *value) {
            auto *state = static_cast<GpuFrames *>(value);
            std::lock_guard<std::mutex> guard(state->lock);
            if (state->lease_started_ns) state->stats.lease_hold.add(airplay::TimingSamples::now_ns() - state->lease_started_ns);
            state->lease_started_ns = 0; state->imported_frame.Reset();
        };
        return &descriptor;
    }
    // Called by the producer; never dispatch/log from Flutter's raster callback.
    // Acquiring a descriptor and releasing its import lease are NOT presentation.
    std::string diagnostics() {
        std::lock_guard<std::mutex> guard(lock);
        const auto now = airplay::TimingSamples::now_ns();
        if (!stats_started_ns || now - stats_started_ns < 5000000000LL) return {};
        char counts[256];
        std::snprintf(counts, sizeof(counts),
            "Windows GPU texture stats: interval_ms=%lld received=%llu acquired_new=%llu overwritten_before_acquire=%llu repeated_acquire=%llu pending=%d size=%zux%zu",
            static_cast<long long>((now - stats_started_ns) / 1000000), static_cast<unsigned long long>(stats.received),
            static_cast<unsigned long long>(stats.acquired_new), static_cast<unsigned long long>(stats.overwritten),
            static_cast<unsigned long long>(stats.repeated), int(sequence != acquired_sequence), width, height);
        auto result = std::string(counts) + stats.acquire_gap.text("acquire_gap")
            + stats.frame_age.text("frame_age") + stats.lease_hold.text("lease_hold");
        stats = {}; stats_started_ns = now;
        return result;
    }
};
