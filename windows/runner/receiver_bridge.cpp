// SPDX-License-Identifier: GPL-3.0-only
#include "receiver_bridge.h"
#include "build_info.h"
#include "../../native/include/airplay/receiver.h"
#include "../../native/backends/windows/windows_video.h"
#include "gpu_video_texture.h"
#include "receiver_json.h"
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <bcrypt.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>
#include <utility>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using Result = flutter::MethodResult<Value>;
std::string string(const Map &args, const char *key, const std::string &fallback = "") {
    const auto found = args.find(Value(key));
    return found != args.end() && std::holds_alternative<std::string>(found->second)
        ? std::get<std::string>(found->second) : fallback;
}
std::string utf8(const std::wstring &value) {
    const int count = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string result(count, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), count, nullptr, nullptr);
    return result;
}
struct PixelFrame { std::vector<uint8_t> pixels; size_t width = 1, height = 1; };
struct Pixels {
    std::mutex lock;
    std::shared_ptr<PixelFrame> frame;
    airplay::TextureStats stats;
    void clear() {
        auto black = std::make_shared<PixelFrame>(); black->pixels = {0, 0, 0, 255};
        std::lock_guard<std::mutex> guard(lock); frame = std::move(black); stats.clear();
    }
    void receive(const airplay::WindowsVideoFrame &input) {
        if (!input.pixels || !input.width || !input.height || input.width > 4096 || input.height > 4096 || input.stride < input.width * 4) return;
        auto copy = std::make_shared<PixelFrame>(); copy->width = input.width; copy->height = input.height;
        copy->pixels.resize(input.width * input.height * 4);
        for (size_t y = 0; y < input.height; ++y)
            std::copy_n(input.pixels + y * input.stride, input.width * 4, copy->pixels.data() + y * input.width * 4);
        std::lock_guard<std::mutex> guard(lock); frame = std::move(copy); stats.receive();
    }
    std::string diagnostics() {
        std::lock_guard<std::mutex> guard(lock);
        return stats.report("Windows pixel", frame ? frame->width : 0, frame ? frame->height : 0);
    }
    const FlutterDesktopPixelBuffer *copy() {
        struct Lease { std::shared_ptr<PixelFrame> frame; FlutterDesktopPixelBuffer buffer{}; };
        auto lease = std::make_unique<Lease>();
        { std::lock_guard<std::mutex> guard(lock); lease->frame = frame; stats.acquire(); }
        if (!lease->frame) return nullptr;
        lease->buffer.buffer = lease->frame->pixels.data(); lease->buffer.width = lease->frame->width;
        lease->buffer.height = lease->frame->height; lease->buffer.release_context = lease.get();
        lease->buffer.release_callback = [](void *context) { delete static_cast<Lease *>(context); };
        auto *buffer = &lease->buffer; lease.release(); return buffer;
    }
};
}

struct ReceiverBridge::Impl {
    HWND window;
    flutter::TextureRegistrar *textures;
    std::shared_ptr<Pixels> pixels = std::make_shared<Pixels>();
    std::shared_ptr<flutter::TextureVariant> texture, gpu_texture;
    std::shared_ptr<GpuFrames> gpu_frames = std::make_shared<GpuFrames>();
    int64_t pixel_texture_id = -1, gpu_texture_id = -1;
    std::atomic<int64_t> submitted_texture_id{-1};
    Microsoft::WRL::ComPtr<IDXGIAdapter> graphics_adapter;
    std::unique_ptr<flutter::MethodChannel<Value>> methods;
    std::function<void(const Map &)> on_snapshot;
    std::mutex dispatch_lock;
    std::deque<std::function<void()>> dispatches;
    uint64_t handle = 0;
    std::string initialization_error;
    std::filesystem::path directory;
    std::array<uint8_t, 6> identity{};
    static std::string encode(const Map &value) {
        return receiver_json::encode(value);
    }
    static Map decode(const char *value) {
        return receiver_json::decode(value);
    }
    Impl(HWND target, flutter::BinaryMessenger *messenger, flutter::TextureRegistrar *registrar,
         std::function<void(const Map &)> callback, IDXGIAdapter *adapter)
        : window(target), textures(registrar), graphics_adapter(adapter), on_snapshot(std::move(callback)) {
        pixels->clear();
        texture = std::make_shared<flutter::TextureVariant>(flutter::PixelBufferTexture(
            [state = pixels](size_t, size_t) { return state->copy(); }));
        pixel_texture_id = textures->RegisterTexture(texture.get()); submitted_texture_id = pixel_texture_id;
        if (graphics_adapter) {
            gpu_texture = std::make_shared<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
                kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
                [state = gpu_frames](size_t, size_t) { return state->copy(); }));
            gpu_texture_id = textures->RegisterTexture(gpu_texture.get());
        }
        load();
        AirplayReceiverHost hooks{}; hooks.context = this;
        hooks.create_player = [](void *context, AirplayCallbacks callbacks, int, int, int, char *error, size_t capacity) {
            auto *self = static_cast<Impl *>(context);
            if (self->pixel_texture_id < 0) { snprintf(error, capacity, "Cannot register Flutter video texture"); return static_cast<AirplayPlayer *>(nullptr); }
            airplay::WindowsVideoOptions options{self->graphics_adapter.Get(), self->gpu_texture_id >= 0};
            return airplay_player_create(callbacks, &options, nullptr, nullptr);
        };
        hooks.texture_id = [](void *context) { return static_cast<Impl *>(context)->submitted_texture_id.load(); };
        hooks.end_video = [](void *context, bool) { static_cast<Impl *>(context)->clear_video(); };
        hooks.clear_video = [](void *context) { static_cast<Impl *>(context)->clear_video(); };
        hooks.frame = [](void *context, void *frame, int64_t) {
            if (!frame) return;
            auto *self = static_cast<Impl *>(context);
            const auto &image = *static_cast<airplay::WindowsVideoFrame *>(frame);
            int64_t id = self->pixel_texture_id;
            if (image.texture && self->gpu_texture_id >= 0 && self->gpu_frames->receive(image)) id = self->gpu_texture_id;
            else if (image.pixels) self->pixels->receive(image); else return;
            if (id != self->submitted_texture_id) {
                if (id == self->gpu_texture_id) self->pixels->clear(); else self->gpu_frames->clear();
            }
            self->submitted_texture_id = id; self->textures->MarkTextureFrameAvailable(id);
        };
        hooks.diagnostics = [](void *context, char *output, size_t capacity) {
            auto *self = static_cast<Impl *>(context);
            const auto report = self->submitted_texture_id == self->gpu_texture_id
                ? self->gpu_frames->diagnostics() : self->pixels->diagnostics();
            if (!report.empty()) snprintf(output, capacity, "%s", report.c_str());
        };
        hooks.event = [](void *context, const char *json) {
            auto *self = static_cast<Impl *>(context); const auto event = decode(json);
            const auto found = event.find(Value("data"));
            if (string(event, "type") == "snapshot" && found != event.end() && std::holds_alternative<Map>(found->second)) {
                auto value = std::get<Map>(found->second);
                self->post([self, value = std::move(value)] { if (self->on_snapshot) self->on_snapshot(value); });
            }
        };
        const auto screen = screen_size();
        Map metadata{{Value("defaultName"), Value(default_name())}, {Value("buildTime"), Value(AIRPLAY_BUILD_TIME)},
            {Value("screenWidth"), Value(screen.first)}, {Value("screenHeight"), Value(screen.second)},
            {Value("capabilities"), Value(Map{
                {Value("platform"), Value("windows")}, {Value("supportsExecutablePath"), Value(false)},
                {Value("supportsLaunchAtLogin"), Value(true)}, {Value("supportsAacEld"), Value(true)}})}};
        char error[512]{};
        if (!directory.empty()) handle = airplay_receiver_create(hooks, encode(metadata).c_str(),
            utf8((directory / L"airplay-pairing.pem").wstring()).c_str(), identity.data(), error, sizeof(error));
        initialization_error = error[0] ? error : "Cannot initialize private receiver configuration";
        methods = std::make_unique<flutter::MethodChannel<Value>>(messenger, "org.airplayreceiver/platform", &flutter::StandardMethodCodec::GetInstance());
        methods->SetMethodCallHandler([this](const flutter::MethodCall<Value> &call, std::unique_ptr<Result> reply) {
            if (call.method_name() != "bootstrap") { reply->NotImplemented(); return; }
            if (!handle) { reply->Error("receiver_error", initialization_error); return; }
            const auto screen = screen_size();
            airplay_receiver_update(handle, encode(Map{{Value("screenWidth"), Value(screen.first)}, {Value("screenHeight"), Value(screen.second)}}).c_str());
            reply->Success(Value(Map{{Value("handle"), Value(static_cast<int64_t>(handle))}}));
        });
    }
    ~Impl() {
        methods->SetMethodCallHandler(nullptr); on_snapshot = {};
        airplay_receiver_destroy(handle);
        if (pixel_texture_id >= 0) textures->UnregisterTexture(pixel_texture_id, [keep = texture] {});
        if (gpu_texture_id >= 0) textures->UnregisterTexture(gpu_texture_id, [keep = gpu_texture] {});
    }
    void post(std::function<void()> task) {
        { std::lock_guard<std::mutex> guard(dispatch_lock); dispatches.push_back(std::move(task)); }
        PostMessageW(window, ReceiverBridge::kDispatchMessage, 0, 0);
    }
    void dispatch() {
        std::deque<std::function<void()>> tasks;
        { std::lock_guard<std::mutex> guard(dispatch_lock); tasks.swap(dispatches); }
        for (auto &task : tasks) task();
    }
    void clear_video() {
        pixels->clear(); gpu_frames->clear(); submitted_texture_id = pixel_texture_id;
        if (pixel_texture_id >= 0) textures->MarkTextureFrameAvailable(pixel_texture_id);
    }
    std::pair<int, int> screen_size() const {
        MONITORINFOEXW monitor{}; monitor.cbSize = sizeof(monitor);
        DEVMODEW mode{}; mode.dmSize = sizeof(mode);
        if (GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), reinterpret_cast<LPMONITORINFO>(&monitor)) &&
            EnumDisplaySettingsW(monitor.szDevice, ENUM_CURRENT_SETTINGS, &mode))
            return {static_cast<int>(mode.dmPelsWidth), static_cast<int>(mode.dmPelsHeight)};
        return {1920, 1080};
    }
    static std::string default_name() {
        wchar_t computer[MAX_COMPUTERNAME_LENGTH + 1]{};
        DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
        if (GetComputerNameW(computer, &size)) {
            return utf8(std::wstring(computer, size));
        }
        return "Flutter AirPlay";
    }
    void load() {
        PWSTR support = nullptr;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &support))) {
            directory = std::filesystem::path(support) / L"FlutterAirPlay"; CoTaskMemFree(support);
            std::error_code error; std::filesystem::create_directories(directory, error);
            if (error) { directory.clear(); return; }
            std::ifstream data(directory / L"identity.dat", std::ios::binary);
            data.read(reinterpret_cast<char *>(identity.data()), identity.size());
            if (data.gcount() != static_cast<std::streamsize>(identity.size())) {
                if (BCryptGenRandom(nullptr, identity.data(), static_cast<ULONG>(identity.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
                    directory.clear(); return;
                }
                identity[0] = (identity[0] | 2) & 254;
                std::ofstream output(directory / L"identity.dat", std::ios::binary);
                output.write(reinterpret_cast<const char *>(identity.data()), identity.size());
                if (!output) directory.clear();
            }

        }
    }

};
ReceiverBridge::ReceiverBridge(HWND window, flutter::BinaryMessenger *messenger, flutter::TextureRegistrar *textures,
                               std::function<void(const flutter::EncodableMap &)> on_snapshot, IDXGIAdapter *adapter)
    : impl_(std::make_unique<Impl>(window, messenger, textures, std::move(on_snapshot), adapter)) {}
ReceiverBridge::~ReceiverBridge() = default;
void ReceiverBridge::Dispatch() { impl_->dispatch(); }
