// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wmcodecdsp.h>
#include <wrl/client.h>
#include <cstdint>
#include <cstring>

namespace airplay {
using Microsoft::WRL::ComPtr;
inline bool windows_media_ready() {
    struct Apartment {
        HRESULT status = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        ~Apartment() { if (SUCCEEDED(status)) CoUninitialize(); }
    };
    thread_local Apartment apartment;
    struct Platform {
        HRESULT status = MFStartup(MF_VERSION, MFSTARTUP_FULL);
        ~Platform() { if (SUCCEEDED(status)) MFShutdown(); }
    };
    static Platform platform;
    return (SUCCEEDED(apartment.status) || apartment.status == RPC_E_CHANGED_MODE) && SUCCEEDED(platform.status);
}
inline ComPtr<IMFSample> windows_sample(const uint8_t *data, size_t size, int64_t deadline) {
    ComPtr<IMFSample> sample;
    ComPtr<IMFMediaBuffer> buffer;
    if (size > UINT32_MAX || FAILED(MFCreateSample(&sample)) ||
        FAILED(MFCreateMemoryBuffer(static_cast<DWORD>(size), &buffer))) return {};
    BYTE *bytes = nullptr;
    if (FAILED(buffer->Lock(&bytes, nullptr, nullptr))) return {};
    std::memcpy(bytes, data, size);
    buffer->Unlock();
    if (FAILED(buffer->SetCurrentLength(static_cast<DWORD>(size))) ||
        FAILED(sample->AddBuffer(buffer.Get())) || FAILED(sample->SetSampleTime(deadline / 100))) return {};
    return sample;
}
inline ComPtr<IMFSample> windows_output_sample(IMFTransform *decoder) {
    MFT_OUTPUT_STREAM_INFO info{};
    if (FAILED(decoder->GetOutputStreamInfo(0, &info))) return {};
    if (info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) return {};
    ComPtr<IMFSample> sample;
    ComPtr<IMFMediaBuffer> buffer;
    DWORD alignment = 16;
    while (alignment < info.cbAlignment && alignment < 4096) alignment *= 2;
    if (!info.cbSize || info.cbSize > 128 * 1024 * 1024 || info.cbAlignment > alignment ||
        FAILED(MFCreateSample(&sample)) ||
        FAILED(MFCreateAlignedMemoryBuffer(info.cbSize, alignment - 1, &buffer)) ||
        FAILED(sample->AddBuffer(buffer.Get()))) return {};
    return sample;
}
inline void windows_begin_stream(IMFTransform *decoder) {
    decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
}
} // namespace airplay
