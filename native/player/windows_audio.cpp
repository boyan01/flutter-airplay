// SPDX-License-Identifier: GPL-3.0-only
#include "platform.h"
#include "windows_media.h"
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <avrt.h>
#include <future>
#include <thread>

namespace airplay {
class WindowsAudio final : public AudioOutput {
public:
    explicit WindowsAudio(std::shared_ptr<AudioBuffer> buffer) : buffer_(std::move(buffer)) {
        stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        audio_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    }
    ~WindowsAudio() override {
        stop(); if (stop_event_) CloseHandle(stop_event_); if (audio_event_) CloseHandle(audio_event_);
    }
    bool start() override {
        std::lock_guard<std::mutex> guard(lock_);
        if (worker_.joinable()) return running_;
        if (!stop_event_ || !audio_event_) return false;
        ResetEvent(stop_event_); ResetEvent(audio_event_);
        std::promise<bool> result; auto ready = result.get_future();
        worker_ = std::thread([this, result = std::move(result)]() mutable { run(std::move(result)); });
        const bool success = ready.get();
        if (!success && worker_.joinable()) worker_.join();
        return success;
    }
    void stop() override {
        std::lock_guard<std::mutex> guard(lock_);
        if (stop_event_) SetEvent(stop_event_);
        if (worker_.joinable()) worker_.join();
        running_ = false;
    }
private:
    struct Device {
        ComPtr<IAudioClient> client;
        ComPtr<IAudioRenderClient> render;
        std::wstring id;
        UINT32 capacity = 0;
        REFERENCE_TIME latency = 0;
        ~Device() { if (client) client->Stop(); }
    };
    std::unique_ptr<Device> open(IMMDeviceEnumerator *enumerator) {
        ComPtr<IMMDevice> endpoint;
        if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &endpoint))) return {};
        auto device = std::make_unique<Device>();
        LPWSTR id = nullptr;
        if (FAILED(endpoint->GetId(&id))) return {};
        device->id = id; CoTaskMemFree(id);
        if (FAILED(endpoint->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                     reinterpret_cast<void **>(device->client.GetAddressOf())))) return {};
        WAVEFORMATEX format{};
        format.wFormatTag = WAVE_FORMAT_PCM; format.nChannels = 2; format.nSamplesPerSec = kSampleRate;
        format.wBitsPerSample = 16; format.nBlockAlign = 4; format.nAvgBytesPerSec = kSampleRate * 4;
        // WASAPI performs sample-rate/channel conversion to the endpoint mix format.
        const DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                            AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        if (FAILED(device->client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 200000, 0, &format, nullptr)) ||
            FAILED(device->client->SetEventHandle(audio_event_)) ||
            FAILED(device->client->GetBufferSize(&device->capacity)) ||
            FAILED(device->client->GetService(IID_PPV_ARGS(&device->render)))) return {};
        device->client->GetStreamLatency(&device->latency);
        BYTE *silence = nullptr;
        if (FAILED(device->render->GetBuffer(device->capacity, &silence)) ||
            FAILED(device->render->ReleaseBuffer(device->capacity, AUDCLNT_BUFFERFLAGS_SILENT)) ||
            FAILED(device->client->Start())) return {};
        return device;
    }
    void run(std::promise<bool> ready) {
        ComPtr<IMMDeviceEnumerator> enumerator;
        if (!windows_media_ready() || FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
            CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) { ready.set_value(false); return; }
        auto device = open(enumerator.Get());
        running_ = bool(device); ready.set_value(running_);
        if (!device) return;
        DWORD task = 0; HANDLE priority = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
        const HANDLE events[] = {stop_event_, audio_event_};
        auto last_device_check = monotonic_ns();
        while (WaitForSingleObject(stop_event_, 0) != WAIT_OBJECT_0) {
            const auto wait = WaitForMultipleObjects(2, events, FALSE, device ? 500 : 250);
            if (wait == WAIT_OBJECT_0 || wait == WAIT_FAILED) break;
            if (!device) { device = open(enumerator.Get()); continue; }
            const auto now = monotonic_ns();
            if (now - last_device_check >= kSecond / 2) {
                last_device_check = now;
                ComPtr<IMMDevice> current; LPWSTR id = nullptr;
                if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &current)) &&
                    SUCCEEDED(current->GetId(&id))) {
                    const bool changed = device->id != id; CoTaskMemFree(id);
                    if (changed) { device.reset(); continue; }
                }
            }
            UINT32 padding = 0;
            if (FAILED(device->client->GetCurrentPadding(&padding)) || padding > device->capacity) {
                device.reset(); continue;
            }
            const auto frames = device->capacity - padding;
            if (!frames) continue;
            BYTE *bytes = nullptr;
            if (FAILED(device->render->GetBuffer(frames, &bytes))) { device.reset(); continue; }
            const auto due = monotonic_ns() + int64_t(padding) * kSecond / kSampleRate + device->latency * 100;
            buffer_->read(reinterpret_cast<int16_t *>(bytes), frames, due);
            if (FAILED(device->render->ReleaseBuffer(frames, 0))) device.reset();
        }
        device.reset(); running_ = false;
        if (priority) AvRevertMmThreadCharacteristics(priority);
    }
    std::shared_ptr<AudioBuffer> buffer_;
    std::mutex lock_;
    std::thread worker_;
    std::atomic<bool> running_{false};
    HANDLE stop_event_ = nullptr, audio_event_ = nullptr;
};
std::unique_ptr<AudioOutput> make_audio_output(std::shared_ptr<AudioBuffer> buffer) {
    return std::make_unique<WindowsAudio>(std::move(buffer));
}
} // namespace airplay
