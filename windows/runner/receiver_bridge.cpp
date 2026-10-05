// SPDX-License-Identifier: GPL-3.0-only
#include "receiver_bridge.h"
#include "build_info.h"
#include "player.h"
#include "windows_video.h"
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <bcrypt.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

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
bool bool_argument(const Map &args, const char *key, bool fallback) {
    const auto found = args.find(Value(key));
    return found != args.end() && std::holds_alternative<bool>(found->second) ? std::get<bool>(found->second) : fallback;
}
std::string utf8(const std::wstring &value) {
    const int count = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    std::string result(count, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), count, nullptr, nullptr);
    return result;
}
std::string time_string() {
    SYSTEMTIME time{}; GetSystemTime(&time); char bytes[40]{};
    std::snprintf(bytes, sizeof(bytes), "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ", time.wYear, time.wMonth,
        time.wDay, time.wHour, time.wMinute, time.wSecond, time.wMilliseconds);
    return bytes;
}
struct PixelFrame { std::vector<uint8_t> pixels; size_t width = 1, height = 1; };
struct Pixels {
    std::mutex lock;
    std::shared_ptr<PixelFrame> frame;
    void clear() {
        auto black = std::make_shared<PixelFrame>(); black->pixels = {0, 0, 0, 255};
        std::lock_guard<std::mutex> guard(lock); frame = std::move(black);
    }
    void receive(const airplay::WindowsVideoFrame &input) {
        if (!input.pixels || !input.width || !input.height || input.width > 4096 || input.height > 4096 || input.stride < input.width * 4) return;
        auto copy = std::make_shared<PixelFrame>(); copy->width = input.width; copy->height = input.height;
        copy->pixels.resize(input.width * input.height * 4);
        for (size_t y = 0; y < input.height; ++y)
            std::copy_n(input.pixels + y * input.stride, input.width * 4, copy->pixels.data() + y * input.width * 4);
        std::lock_guard<std::mutex> guard(lock); frame = std::move(copy);
    }
    const FlutterDesktopPixelBuffer *copy() {
        struct Lease { std::shared_ptr<PixelFrame> frame; FlutterDesktopPixelBuffer buffer{}; };
        auto lease = std::make_unique<Lease>();
        { std::lock_guard<std::mutex> guard(lock); lease->frame = frame; }
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
    std::shared_ptr<flutter::TextureVariant> texture;
    int64_t texture_id = -1;
    std::unique_ptr<flutter::MethodChannel<Value>> methods;
    std::function<void(const Map &)> on_snapshot;
    std::unique_ptr<flutter::EventChannel<Value>> events;
    std::unique_ptr<flutter::EventSink<Value>> sink;
    std::mutex command_lock, dispatch_lock;
    std::condition_variable wake;
    std::deque<std::function<void()>> commands, dispatches;
    std::thread worker;
    bool closing = false;
    std::atomic<uint64_t> generation{0};
    struct Context { Impl *host; uint64_t generation; };
    std::unique_ptr<Context> context;
    AirplayPlayer *player = nullptr;
    std::string name = "Flutter AirPlay", status = "stopped", message = "接收器未启动", client;
    std::string receiving_name;
    std::filesystem::path directory;
    std::array<uint8_t, 6> identity{};
    bool auto_start = true, audio = false, paused = false;
    int width = 0, height = 0;
    int64_t log_id = 0;
    List logs;
    bool keep_in_tray = true, show_on_connect = true, fullscreen_on_connect = false;
    bool always_on_top = false, launch_at_login = false;

    Impl(HWND target, flutter::BinaryMessenger *messenger, flutter::TextureRegistrar *registrar, std::function<void(const Map &)> callback)
        : window(target), textures(registrar), on_snapshot(std::move(callback)) {
        pixels->clear();
        texture = std::make_shared<flutter::TextureVariant>(flutter::PixelBufferTexture(
            [state = pixels](size_t, size_t) { return state->copy(); }));
        texture_id = textures->RegisterTexture(texture.get());
        methods = std::make_unique<flutter::MethodChannel<Value>>(messenger, "org.airplayreceiver/control", &flutter::StandardMethodCodec::GetInstance());
        events = std::make_unique<flutter::EventChannel<Value>>(messenger, "org.airplayreceiver/events", &flutter::StandardMethodCodec::GetInstance());
        events->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
            [this](const Value *, std::unique_ptr<flutter::EventSink<Value>> next) -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
                sink = std::move(next); enqueue([this] { emit(Map{{Value("type"), Value("snapshot")}, {Value("data"), Value(snapshot())}}); }); return nullptr;
            }, [this](const Value *) -> std::unique_ptr<flutter::StreamHandlerError<Value>> { sink.reset(); return nullptr; }));
        methods->SetMethodCallHandler([this](const flutter::MethodCall<Value> &call, std::unique_ptr<Result> result) {
            const auto method = call.method_name(); Map args;
            if (call.arguments() && std::holds_alternative<Map>(*call.arguments())) args = std::get<Map>(*call.arguments());
            auto reply = std::shared_ptr<Result>(std::move(result));
            enqueue([this, method, args, reply] { command(method, args, reply); });
        });
        worker = std::thread([this] {
            load();
            auto initial = snapshot(); post([this, initial] { on_snapshot(initial); });
            for (;;) {
                std::function<void()> task;
                { std::unique_lock<std::mutex> guard(command_lock); wake.wait(guard, [this] { return closing || !commands.empty(); });
                  if (closing) break; task = std::move(commands.front()); commands.pop_front(); }
                task();
            }
            stop();
        });
    }
    ~Impl() {
        methods->SetMethodCallHandler(nullptr); events->SetStreamHandler(nullptr); sink.reset();
        { std::lock_guard<std::mutex> guard(command_lock); closing = true; commands.clear(); }
        wake.notify_all(); if (worker.joinable()) worker.join();
        // Keep the registrar callback alive until Flutter confirms unregistration.
        if (texture_id >= 0) textures->UnregisterTexture(texture_id, [keep = texture] {});
    }
    void enqueue(std::function<void()> task) {
        { std::lock_guard<std::mutex> guard(command_lock); if (closing) return; commands.push_back(std::move(task)); }
        wake.notify_one();
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
    void emit(Map event) {
        const bool changed = string(event, "type") != "log";
        auto current = changed ? snapshot() : Map{};
        post([this, event = std::move(event), current = std::move(current), changed] {
            if (sink) sink->Success(Value(event));
            if (changed) on_snapshot(current);
        });
    }
    void state(const std::string &next, const std::string &detail) {
        status = next; message = detail;
        if (next == "waiting" || next == "stopping" || next == "stopped" || next == "error") {
            client.clear(); width = height = 0; audio = paused = false; pixels->clear();
        }
        emit(Map{{Value("type"), Value("state")}, {Value("status"), Value(next)}, {Value("message"), Value(detail)},
                 {Value("pid"), Value(player ? static_cast<int64_t>(GetCurrentProcessId()) : 0)}});
    }
    void log(std::string text) {
        text.resize(std::min<size_t>(text.size(), 4096));
        Map entry{{Value("id"), Value(++log_id)}, {Value("time"), Value(time_string())}, {Value("text"), Value(text)}};
        logs.emplace_back(entry); if (logs.size() > 300) logs.erase(logs.begin());
        emit(Map{{Value("type"), Value("log")}, {Value("entry"), Value(entry)}});
    }
    Map snapshot() const {
        return Map{{Value("status"), Value(status)}, {Value("message"), Value(message)}, {Value("name"), Value(name)},
            {Value("buildTime"), Value(AIRPLAY_BUILD_TIME)},
            {Value("receivingName"), Value(receiving_name)},
            {Value("path"), Value("")}, {Value("autoStart"), Value(auto_start)},
            {Value("keepInMenuBar"), Value(keep_in_tray)}, {Value("showOnConnect"), Value(show_on_connect)},
            {Value("fullscreenOnConnect"), Value(fullscreen_on_connect)}, {Value("alwaysOnTop"), Value(always_on_top)},
            {Value("launchAtLogin"), Value(launch_at_login)}, {Value("clientName"), Value(client)},
            {Value("pid"), Value(player ? static_cast<int64_t>(GetCurrentProcessId()) : 0)}, {Value("textureId"), Value(texture_id)},
            {Value("videoWidth"), Value(width)}, {Value("videoHeight"), Value(height)}, {Value("audioPlaying"), Value(audio)},
            {Value("videoPaused"), Value(paused)}, {Value("logs"), Value(logs)},
            {Value("capabilities"), Value(Map{{Value("platform"), Value("windows")}, {Value("supportsExecutablePath"), Value(false)},
                {Value("supportsLaunchAtLogin"), Value(true)}, {Value("supportsAacEld"), Value(true)}})}};
    }
    void load() {
        wchar_t computer[MAX_COMPUTERNAME_LENGTH + 1]{};
        DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
        if (GetComputerNameW(computer, &size)) {
            const auto device_name = utf8(std::wstring(computer, size));
            if (valid_name(device_name)) name = device_name;
        }
        PWSTR support = nullptr;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &support))) {
            directory = std::filesystem::path(support) / L"FlutterAirPlay"; CoTaskMemFree(support);
            std::error_code error; std::filesystem::create_directories(directory, error);
            if (error) { directory.clear(); return; }
            std::ifstream settings(directory / L"settings.txt", std::ios::binary); std::string saved;
            const bool has_saved_name = std::getline(settings, saved) && valid_name(saved);
            if (has_saved_name) name = saved;
            if (std::getline(settings, saved)) auto_start = saved != "0";
            for (auto *option : {&keep_in_tray, &show_on_connect, &fullscreen_on_connect, &always_on_top}) {
                if (std::getline(settings, saved)) *option = saved != "0";
            }
            launch_at_login = login_enabled();
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
            settings.close();
            if (!has_saved_name && !directory.empty()) save(Map{{Value("name"), Value(name)}});
        }
    }
    static std::wstring login_command() {
        std::wstring path(32768, L'\0');
        const auto length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
        if (!length || length >= path.size()) return {};
        path.resize(length); return L"\"" + path + L"\"";
    }
    static bool login_enabled() {
        DWORD size = 0;
        constexpr auto key = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        if (RegGetValueW(HKEY_CURRENT_USER, key, L"FlutterAirPlay", RRF_RT_REG_SZ, nullptr, nullptr, &size) != ERROR_SUCCESS
            || size > 65536 || size < sizeof(wchar_t)) return false;
        std::wstring value(size / sizeof(wchar_t), L'\0');
        if (RegGetValueW(HKEY_CURRENT_USER, key, L"FlutterAirPlay", RRF_RT_REG_SZ, nullptr, value.data(), &size) != ERROR_SUCCESS) return false;
        value.resize(wcslen(value.c_str())); return value == login_command();
    }
    static bool set_login(bool enabled) {
        HKEY key = nullptr;
        constexpr auto path = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        auto error = enabled
            ? RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr)
            : RegOpenKeyExW(HKEY_CURRENT_USER, path, 0, KEY_SET_VALUE, &key);
        if (!enabled && error == ERROR_FILE_NOT_FOUND) return true;
        if (error != ERROR_SUCCESS) return false;
        if (enabled) {
            const auto command = login_command();
            error = command.empty() ? ERROR_INVALID_DATA : RegSetValueExW(key, L"FlutterAirPlay", 0, REG_SZ,
                reinterpret_cast<const BYTE *>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
        } else {
            error = RegDeleteValueW(key, L"FlutterAirPlay");
            if (error == ERROR_FILE_NOT_FOUND) error = ERROR_SUCCESS;
        }
        RegCloseKey(key); return error == ERROR_SUCCESS;
    }
    static bool valid_name(const std::string &value) {
        return !value.empty() && value.size() <= 50 &&
            std::none_of(value.begin(), value.end(), [](unsigned char byte) { return byte < 32 || byte == 127; }) &&
            MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0) > 0;
    }
    std::string save(const Map &args) {
        auto next = string(args, "name");
        const auto begin = next.find_first_not_of(" \t\r\n"), end = next.find_last_not_of(" \t\r\n");
        next = begin == std::string::npos ? "" : next.substr(begin, end - begin + 1);
        if (!string(args, "path").empty()) return "Windows 使用内置接收核心，无需指定路径。";
        if (!valid_name(next)) return "设备名需要 1–50 个 UTF-8 字节，不能含控制字符。";
        if (directory.empty()) return "无法创建接收器的本地配置目录。";
        const auto automatic = bool_argument(args, "autoStart", auto_start);
        const auto keep = bool_argument(args, "keepInMenuBar", keep_in_tray);
        const auto show = bool_argument(args, "showOnConnect", show_on_connect);
        const auto full = bool_argument(args, "fullscreenOnConnect", fullscreen_on_connect);
        const auto top = bool_argument(args, "alwaysOnTop", always_on_top);
        const auto login = bool_argument(args, "launchAtLogin", launch_at_login);
        if (login != launch_at_login && !set_login(login)) return "无法更新当前用户的登录启动设置。";
        std::ofstream output(directory / L"settings.txt", std::ios::binary | std::ios::trunc);
        output << next << '\n' << (automatic ? '1' : '0') << '\n'
            << keep << '\n' << show << '\n' << full << '\n' << top << '\n'; output.close();
        if (!output) {
            if (login != launch_at_login) set_login(launch_at_login);
            return "无法保存接收器配置。";
        }
        name = std::move(next); auto_start = automatic; keep_in_tray = keep;
        show_on_connect = show; fullscreen_on_connect = full; always_on_top = top; launch_at_login = login;
        return "";
    }

    void clear_video() { pixels->clear(); textures->MarkTextureFrameAvailable(texture_id); width = height = 0;
        emit(Map{{Value("type"), Value("video")}, {Value("textureId"), Value(texture_id)}, {Value("videoWidth"), Value(0)}, {Value("videoHeight"), Value(0)}}); }
    void media() { emit(Map{{Value("type"), Value("media")}, {Value("audioPlaying"), Value(audio)}, {Value("videoPaused"), Value(paused)}}); }
    void receive(const std::string &event, const std::string &detail, int w, int h) {
        if (!player) return;
        if (event == "client") { client = detail; emit(Map{{Value("type"), Value("client")}, {Value("name"), Value(detail)}}); }
        if (event == "client" || event == "connecting") state("streaming", "已建立连接，等待第一帧画面");
        else if (event == "playing") {
            if (paused) { paused = false; media(); }
            if (width != w || height != h) { width = w; height = h;
                emit(Map{{Value("type"), Value("video")}, {Value("textureId"), Value(texture_id)}, {Value("videoWidth"), Value(w)}, {Value("videoHeight"), Value(h)}}); }
            if (message != "正在播放屏幕镜像") state("streaming", "正在播放屏幕镜像");
        } else if (event == "waiting") { clear_video(); state("waiting", "连接已结束 · 等待下一次投屏"); }
        else if (event == "paused" || event == "reset") { paused = event == "paused"; if (!paused) audio = false; clear_video(); media(); }
        else if (event == "audio" || event == "audio_stopped") { audio = event == "audio"; media();
            if (audio && !width) state("streaming", "音频播放中"); }
        else if (event == "error") { stop(); state("error", detail); }
    }
    std::string start() {
        if (player) return "";
        if (texture_id < 0) return "无法注册 Flutter 视频纹理。";
        if (directory.empty()) return "无法创建接收器的本地配置目录。";
        state("starting", "正在注册 Windows 接收服务…");
        context = std::make_unique<Context>(Context{this, ++generation});
        AirplayCallbacks callbacks{}; callbacks.context = context.get();
        callbacks.event = [](void *opaque, const char *type, const char *detail, int width, int height) {
            auto *callback = static_cast<Context *>(opaque); auto *host = callback->host; const auto token = callback->generation;
            const std::string event = type ? type : "", text = detail ? detail : "";
            host->enqueue([host, token, event, text, width, height] { if (token == host->generation) host->receive(event, text, width, height); });
        };
        callbacks.log = [](void *opaque, int, const char *message) {
            auto *callback = static_cast<Context *>(opaque); auto *host = callback->host; const auto token = callback->generation;
            const std::string text = message ? message : "";
            host->enqueue([host, token, text] { if (token == host->generation) {
                host->log(text);
                if (text.find("Unsupported Windows") == 0 ||
                    text.find("Unavailable Windows") == 0) host->receive("error", text, 0, 0);
            } });
        };
        callbacks.frame = [](void *opaque, void *frame) {
            auto *callback = static_cast<Context *>(opaque);
            if (!frame || callback->generation != callback->host->generation) return;
            callback->host->pixels->receive(*static_cast<airplay::WindowsVideoFrame *>(frame));
            callback->host->textures->MarkTextureFrameAvailable(callback->host->texture_id);
        };
        player = airplay_player_create(callbacks, nullptr, nullptr, nullptr);
        if (!player) { context.reset(); state("error", "无法初始化原生播放库。"); return message; }
        char error[512]{};
        const auto key = utf8((directory / L"airplay-pairing.pem").wstring());
        receiving_name = name;
        if (!airplay_player_start(player, name.c_str(), identity.data(), key.c_str(), error, sizeof(error))) {
            const std::string detail = error; stop(); state("error", detail); return detail;
        }
        log("Windows: H.264 / ALAC / AAC-LC / AAC-ELD; AAC uses the shared FFmpeg decoder.");
        state("waiting", "等待 iPhone · 请在控制中心选择此设备"); return "";
    }
    void stop() {
        ++generation;
        if (player) { state("stopping", "正在停止接收器…"); airplay_player_destroy(player); player = nullptr; }
        context.reset(); clear_video(); state("stopped", "接收器已停止");
    }
    void command(const std::string &method, const Map &args, const std::shared_ptr<Result> &reply) {
        std::string error;
        if (method == "snapshot") { auto value = snapshot(); post([reply, value] { reply->Success(Value(value)); }); return; }
        if (method == "save" || method == "start") {
            error = save(args);
            if (error.empty() && method == "start") error = start();
            if (error.empty()) emit(Map{{Value("type"), Value("snapshot")}, {Value("data"), Value(snapshot())}});
        } else if (method == "stop") stop();
        else if (method == "check") {
            if (!string(args, "path").empty()) error = "Windows 使用内置接收核心。";
            else log("Built-in player loaded: Media Foundation H.264, shared FFmpeg AAC-LC/AAC-ELD, Apple ALAC and WASAPI.");
        } else { post([reply] { reply->NotImplemented(); }); return; }
        post([reply, error] { if (error.empty()) reply->Success(); else reply->Error("receiver_error", error); });
    }
};
ReceiverBridge::ReceiverBridge(HWND window, flutter::BinaryMessenger *messenger, flutter::TextureRegistrar *textures,
                               std::function<void(const flutter::EncodableMap &)> on_snapshot)
    : impl_(std::make_unique<Impl>(window, messenger, textures, std::move(on_snapshot))) {}
ReceiverBridge::~ReceiverBridge() = default;
void ReceiverBridge::Dispatch() { impl_->dispatch(); }
