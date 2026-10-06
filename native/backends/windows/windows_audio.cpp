// SPDX-License-Identifier: GPL-3.0-only
#include "../../playback/platform.h"
#include "../../playback/audio_clock.h"
#include "windows_media.h"
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <avrt.h>
#include <future>
#include <sstream>
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
    std::string diagnostics() override {
        std::ostringstream out;
        out << "Windows audio output: backend=WASAPI rate=" << kSampleRate
            << " channels=2 buffer_frames=" << capacity_.load()
            << " latency_us=" << latency_us_.load() << " running=" << running_.load()
            << " device_open_total=" << opens_.load() << " device_error_total=" << errors_.load()
            << " endpoint_empty_total=" << empty_.load() << " wait_timeout_total=" << timeouts_.load()
            << " mmcss=" << mmcss_.load()
            << " last_hresult=0x" << std::hex << uint32_t(last_error_.load()) << std::dec
            << " pcm_late_drop_total=" << buffer_->late_drops()
            << " pcm_stale_drop_total=" << buffer_->stale_drops() << " gain=" << buffer_->gain();
        return out.str();
    }
private:
    bool failed(HRESULT result) {
        if (SUCCEEDED(result)) return false;
        last_error_ = result;
        return true;
    }
    struct Device {
        ComPtr<IAudioClient> client;
        ComPtr<IAudioRenderClient> render;
        std::wstring id;
        UINT32 capacity = 0;
        REFERENCE_TIME latency = 0;
        AudioClock clock;
        uint64_t generation = 0;
        ~Device() { if (client) client->Stop(); }
    };
    std::unique_ptr<Device> open(IMMDeviceEnumerator *enumerator) {
        ComPtr<IMMDevice> endpoint;
        if (failed(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &endpoint))) return {};
        auto device = std::make_unique<Device>();
        LPWSTR id = nullptr;
        if (failed(endpoint->GetId(&id))) return {};
        device->id = id; CoTaskMemFree(id);
        if (failed(endpoint->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                     reinterpret_cast<void **>(device->client.GetAddressOf())))) return {};
        WAVEFORMATEX format{};
        format.wFormatTag = WAVE_FORMAT_PCM; format.nChannels = 2; format.nSamplesPerSec = kSampleRate;
        format.wBitsPerSample = 16; format.nBlockAlign = 4; format.nAvgBytesPerSec = kSampleRate * 4;
        // WASAPI performs sample-rate/channel conversion to the endpoint mix format.
        const DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                            AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        if (failed(device->client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 200000, 0, &format, nullptr)) ||
            failed(device->client->SetEventHandle(audio_event_)) ||
            failed(device->client->GetBufferSize(&device->capacity)) ||
            failed(device->client->GetService(IID_PPV_ARGS(&device->render)))) return {};
        device->client->GetStreamLatency(&device->latency);
        BYTE *silence = nullptr;
        if (failed(device->render->GetBuffer(device->capacity, &silence)) ||
            failed(device->render->ReleaseBuffer(device->capacity, AUDCLNT_BUFFERFLAGS_SILENT)) ||
            failed(device->client->Start())) return {};
        device->generation = buffer_->generation();
        capacity_ = device->capacity; latency_us_ = device->latency / 10;
        ++opens_;
        return device;
    }
    void run(std::promise<bool> ready) {
        ComPtr<IMMDeviceEnumerator> enumerator;
        if (!windows_media_ready() || failed(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
            CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) { ++errors_; ready.set_value(false); return; }
        auto device = open(enumerator.Get());
        running_ = bool(device); ready.set_value(running_);
        if (!device) { ++errors_; return; }
        DWORD task = 0; HANDLE priority = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
        mmcss_ = priority != nullptr;
        const HANDLE events[] = {stop_event_, audio_event_};
        auto last_device_check = monotonic_ns();
        while (WaitForSingleObject(stop_event_, 0) != WAIT_OBJECT_0) {
            const auto wait = WaitForMultipleObjects(2, events, FALSE, device ? 500 : 250);
            if (wait == WAIT_OBJECT_0 || wait == WAIT_FAILED) break;
            if (wait == WAIT_TIMEOUT) ++timeouts_;
            if (!device) {
                device = open(enumerator.Get());
                if (!device) ++errors_;
                continue;
            }
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
            if (failed(device->client->GetCurrentPadding(&padding)) || padding > device->capacity) {
                ++errors_; device.reset(); continue;
            }
            const auto measured = monotonic_ns();
            const auto frames = device->capacity - padding;
            if (!frames) continue;
            const auto generation = buffer_->generation();
            if (generation != device->generation || !padding) {
                // A flush or drained endpoint needs a fresh presentation anchor.
                // Normal event/padding jitter must not cut or repeat PCM samples.
                device->clock.reset(); device->generation = generation;
            }
            if (!padding) ++empty_;
            BYTE *bytes = nullptr;
            if (failed(device->render->GetBuffer(frames, &bytes))) { ++errors_; device.reset(); continue; }
            const auto estimate = measured + int64_t(padding) * kSecond / kSampleRate + device->latency * 100;
            buffer_->read(reinterpret_cast<int16_t *>(bytes), frames, device->clock.next(frames, estimate));
            if (failed(device->render->ReleaseBuffer(frames, 0))) { ++errors_; device.reset(); }
        }
        device.reset(); running_ = false;
        if (priority) AvRevertMmThreadCharacteristics(priority);
        mmcss_ = false;
    }
    std::shared_ptr<AudioBuffer> buffer_;
    std::mutex lock_;
    std::thread worker_;
    std::atomic<bool> running_{false};
    std::atomic<UINT32> capacity_{0};
    std::atomic<int64_t> latency_us_{0};
    std::atomic<uint64_t> opens_{0}, errors_{0}, empty_{0}, timeouts_{0};
    std::atomic<bool> mmcss_{false};
    std::atomic<HRESULT> last_error_{S_OK};
    HANDLE stop_event_ = nullptr, audio_event_ = nullptr;
};
std::unique_ptr<AudioOutput> make_audio_output(std::shared_ptr<AudioBuffer> buffer) {
    return std::make_unique<WindowsAudio>(std::move(buffer));
}
} // namespace airplay
