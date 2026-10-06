// SPDX-License-Identifier: GPL-3.0-only
#include "../../include/airplay/receiver_ffi.h"
#include "../../include/airplay/receiver.h"
#include "../../receiver/json.h"
#include "../../playback/texture_stats.h"
#include <dart_native_api.h>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <vector>

namespace {
using namespace airplay;
void require(bool value, const char* detail) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", detail); std::exit(1); }
}
using Snapshot = std::unique_ptr<AirplayReceiverSnapshot, decltype(&airplay_receiver_free_snapshot)>;
std::mutex messages_lock;
std::condition_variable messages_ready;
std::vector<std::pair<Dart_Port, std::string>> messages;
bool post(Dart_Port port, Dart_CObject* object) {
    require(object->type == Dart_CObject_kString, "events and completion notifications are copied");
    std::lock_guard<std::mutex> guard(messages_lock);
    messages.emplace_back(port, object->value.as_string); messages_ready.notify_all(); return true;
}
Json completion(Dart_Port port, int64_t request) {
    std::unique_lock<std::mutex> guard(messages_lock);
    for (;;) {
        for (auto it = messages.begin(); it != messages.end(); ++it) {
            auto value = parse_json(it->second.c_str());
            if (it->first == port && text(value.get(), "type") == "complete" && integer(value.get(), "request") == request) {
                messages.erase(it); return value;
            }
        }
        require(messages_ready.wait_for(guard, std::chrono::seconds(3)) != std::cv_status::timeout, "command completes without a platform main loop");
    }
}
Json reply(Dart_Port port, int64_t request) { return completion(port, request); }
bool command(uint64_t handle, uint64_t token, int64_t request, const char* method, const char* arguments = "{}") {
    const auto bytes = std::string("{\"method\":\"") + method + "\",\"arguments\":" + arguments + "}";
    return airplay_receiver_control(handle, token, request, bytes.data(), bytes.size());
}
Snapshot snapshot(uint64_t handle) {
    char error[512]{}; Snapshot result(airplay_receiver_snapshot(handle, error, sizeof(error)), airplay_receiver_free_snapshot);
    require(bool(result), "typed snapshot allocated"); return result;
}
struct Preferences {
    std::mutex lock;
    std::condition_variable wake;
    bool block = false, entered = false, reject = false;
};
}
int main() {
    TextureStats texture_stats;
    texture_stats.receive(); texture_stats.receive(); texture_stats.acquire(); texture_stats.acquire(); texture_stats.receive();
    require(texture_stats.received == 3 && texture_stats.acquired_new == 1 && texture_stats.overwritten == 1 && texture_stats.repeated == 1,
            "texture diagnostics distinguish overwritten and repeatedly acquired frames");
    texture_stats.report("Fixture", 128, 72);
    const auto stalled = texture_stats.report("Fixture", 128, 72);
    require(stalled.find("received=0") != std::string::npos && stalled.find("pending=1") != std::string::npos,
            "zero-count output reports preserve stall markers");
    texture_stats.clear(); require(texture_stats.report("Fixture", 128, 72).empty(), "clear resets reconnect timing");

    Preferences preferences;
    AirplayReceiverHost host{}; host.context = &preferences;
    host.preferences = [](void* context, const char*, char* error, size_t capacity) {
        auto* prefs = static_cast<Preferences*>(context); std::unique_lock<std::mutex> guard(prefs->lock);
        prefs->entered = true; prefs->wake.notify_all(); prefs->wake.wait(guard, [&] { return !prefs->block; });
        if (prefs->reject) { snprintf(error, capacity, "Synthetic preferences failure"); return false; }
        return true;
    };
    host.create_player = [](void*, AirplayCallbacks, int, int, int, char* error, size_t capacity) -> AirplayPlayer* {
        snprintf(error, capacity, "Synthetic output failure"); return nullptr;
    };
    uint8_t identity[6]{2,0,0,0,0,1}; char error[512]{};
    const auto handle = airplay_receiver_create(host,
        "{\"defaultName\":\"Fixture\",\"screenHeight\":1080,\"capabilities\":{\"platform\":\"macos\"}}", "unused-key", identity, error, sizeof(error));
    require(handle != 0, "receiver creation");
    const auto token = airplay_receiver_attach(handle, 10, reinterpret_cast<void*>(post));
    require(token != 0, "Dart subscription");
    std::string name = "Copied 测试";
    AirplayReceiverSettings settings{}; settings.fields = AIRPLAY_SETTING_NAME | AIRPLAY_SETTING_FAST_PAIRING;
    settings.name = name.data(); settings.name_size = name.size(); settings.fast_pairing = true;
    std::string input = "{\"method\":\"save\",\"arguments\":{\"name\":\"Copied 测试\",\"fastPairing\":true,\"showPlaybackStats\":true}}";
    require(airplay_receiver_control(handle, token, 1, input.data(), input.size()), "JSON save admitted");
    input.assign(input.size(), 'x');
    name.assign(name.size(), 'x');
    require(!item(reply(10, 1).get(), "error"), "submission owns argument bytes");
    auto saved = snapshot(handle);
    require(std::string(saved->settings.name) == "Copied 测试" && saved->settings.fast_pairing && saved->settings.show_playback_stats, "typed Unicode and overlay settings preserved");
    require(saved->settings.auto_start && saved->settings.keep_in_menu_bar && saved->settings.show_on_connect,
            "partial saves retain shared defaults");
    preferences.reject = true;
    settings.fields = AIRPLAY_SETTING_ALWAYS_ON_TOP; settings.always_on_top = true;
    require(!airplay_receiver_save(handle, &settings, error, sizeof(error)), "platform preferences failure aborts typed save");
    require(!snapshot(handle)->settings.always_on_top, "failed save retains runtime settings");
    preferences.reject = false;
    settings.fields = AIRPLAY_SETTING_NAME;
    for (const auto& invalid : {std::string(""), std::string("bad\0name", 8)}) {
        settings.name = invalid.data(); settings.name_size = invalid.size();
        require(!airplay_receiver_save(handle, &settings, error, sizeof(error)), "invalid names rejected without committing");
    }
    settings.fields = AIRPLAY_SETTING_VIDEO_QUALITY; settings.video_quality = -1;
    require(!airplay_receiver_save(handle, &settings, error, sizeof(error)), "invalid enum rejected");
    name = "Pending"; settings.fields = AIRPLAY_SETTING_NAME; settings.name = name.data(); settings.name_size = name.size();
    { std::lock_guard<std::mutex> guard(preferences.lock); preferences.block = true; preferences.entered = false; }
    require(command(handle, token, 2, "save", "{\"name\":\"Pending\"}"), "pending command admitted");
    {
        std::unique_lock<std::mutex> guard(preferences.lock);
        require(preferences.wake.wait_for(guard, std::chrono::seconds(3), [&] { return preferences.entered; }), "worker entered platform hook");
    }
    std::string cancelled = "Cancelled";
    settings.name = cancelled.data(); settings.name_size = cancelled.size();
    require(command(handle, token, 7, "save", "{\"name\":\"Cancelled\"}"), "old isolate command queued behind platform hook");
    const auto replacement = airplay_receiver_attach(handle, 20, reinterpret_cast<void*>(post));
    require(replacement != token && !airplay_receiver_detach(handle, token), "old isolate cannot detach its replacement");
    require(!command(handle, token, 3, "snapshot"), "stale subscription rejected immediately");
    { std::lock_guard<std::mutex> guard(preferences.lock); preferences.block = false; preferences.wake.notify_all(); }
    require(command(handle, replacement, 4, "snapshot"), "replacement commands admitted");
    auto restored = reply(20, 4);
    require(text(item(restored.get(), "data"), "name") == "Pending", "hot restart retains receiver runtime");
    require(!airplay_receiver_start(handle, UINT64_MAX, error, sizeof(error)), "output failure propagated");
    require(snapshot(handle)->status == AIRPLAY_RECEIVER_ERROR && snapshot(handle)->pid == 0, "failed startup cleans receiver");
    const auto old_generation = snapshot(handle)->generation;
    require(airplay_receiver_stop(handle, error, sizeof(error)), "stop recovers after failed startup");
    require(!airplay_receiver_start(handle, old_generation, error, sizeof(error)) && std::string(error) == "Receiver startup was cancelled",
            "explicit stop cancels an in-flight prepared start");
    require(snapshot(handle)->status == AIRPLAY_RECEIVER_STOPPED, "cancelled startup retains stopped state");
    airplay_receiver_log(handle, "Unicode diagnostic 测试");
    auto logged = snapshot(handle);
    require(logged->log_count && std::string(logged->logs[logged->log_count - 1].text) == "Unicode diagnostic 测试", "typed logs preserve Unicode");
    require(command(handle, replacement, 8, "disconnect"), "session disconnect uses the same asynchronous control adapter");
    require(item(reply(20, 8).get(), "error") != nullptr, "disconnect startup failure reaches the Dart result");
    require(snapshot(handle)->status == AIRPLAY_RECEIVER_ERROR, "failed disconnect retains recoverable state");
    require(command(handle, replacement, 5, "snapshot"), "command admitted before close");
    for (const auto& args : {"{\"videoQuality\":\"invalid\"}", "{\"autoStart\":\"yes\"}", "{\"name\":\"bad\\u0000name\"}"}) {
        require(command(handle, replacement, 9, "save", args), "invalid JSON settings admitted");
        require(item(reply(20, 9).get(), "error"), "invalid settings complete with an error");
    }
    require(command(handle, replacement, 10, "unknown"), "unknown command admitted");
    require(item(reply(20, 10).get(), "error"), "unknown command completes with an error");
    const std::string malformed = "{";
    require(airplay_receiver_control(handle, replacement, 12, malformed.data(), malformed.size()), "malformed JSON admitted");
    require(item(reply(20, 12).get(), "error"), "malformed JSON completes with an error");
    require(command(handle, replacement, 13, "start", "{\"generation\":1.5}"), "invalid generation admitted");
    require(item(reply(20, 13).get(), "error"), "fractional generation is rejected");
    require(command(handle, replacement, 11, "applySettings"), "idle apply admitted");
    require(!boolean(item(reply(20, 11).get(), "data"), "applied", true), "apply result is a JSON boolean");
    airplay_receiver_destroy(handle); completion(20, 5);
    require(!command(handle, replacement, 6, "snapshot"), "destroyed handle rejected safely");
    require(!airplay_receiver_detach(handle, replacement), "detach destroyed host is harmless");
    puts("PASS: JSON FFI control, copied inputs, validation, isolate replacement and recovery");
}
