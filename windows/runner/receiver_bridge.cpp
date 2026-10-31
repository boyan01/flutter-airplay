// SPDX-License-Identifier: GPL-3.0-only
#include "receiver_bridge.h"
#include "build_info.h"
#include "../../native/include/airplay/receiver.h"
#include "receiver_json.h"
#include <lychee_player/lychee_host_texture.h>
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
}

struct ReceiverBridge::Impl {
    HWND window;
    // Pulls the player's frames; outlives every player, freed after the receiver.
    LycheeHostTexture *texture;
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
    Impl(HWND target, flutter::BinaryMessenger *messenger, FlutterDesktopPluginRegistrarRef registrar,
         std::function<void(const Map &)> callback)
        : window(target), texture(LycheeHostTextureCreate(registrar)), on_snapshot(std::move(callback)) {
        load();
        AirplayReceiverHost hooks{}; hooks.context = this;
        hooks.create_player = [](void *context, AirplayCallbacks callbacks, int, int, int, char *error, size_t capacity) {
            auto *self = static_cast<Impl *>(context);
            if (!self->texture) { snprintf(error, capacity, "Cannot register Flutter video texture"); return static_cast<AirplayPlayer *>(nullptr); }
            const AirplayVideoTexture video{self->texture, LycheeHostTextureFrameTypes(), [](void *texture, lychee_player *player) {
                LycheeHostTextureSetPlayer(static_cast<LycheeHostTexture *>(texture), player);
            }};
            return airplay_player_create(callbacks, nullptr, &video);
        };
        hooks.texture_id = [](void *context) {
            auto *texture = static_cast<Impl *>(context)->texture;
            return texture ? LycheeHostTextureGetId(texture) : int64_t(-1);
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
        if (texture) LycheeHostTextureDestroy(texture);
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
ReceiverBridge::ReceiverBridge(HWND window, flutter::BinaryMessenger *messenger, FlutterDesktopPluginRegistrarRef registrar,
                               std::function<void(const flutter::EncodableMap &)> on_snapshot)
    : impl_(std::make_unique<Impl>(window, messenger, registrar, std::move(on_snapshot))) {}
ReceiverBridge::~ReceiverBridge() = default;
void ReceiverBridge::Dispatch() { impl_->dispatch(); }
