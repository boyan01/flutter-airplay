// SPDX-License-Identifier: GPL-3.0-only
#include "../../include/airplay/receiver.h"
#include "../../receiver/receiver_internal.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {
void require(bool condition, const char* message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
struct Observer final : airplay::ReceiverObserver {
    std::vector<std::string> events;
    bool closed = false;
    void deliver(const std::string& bytes) override { events.push_back(bytes); }
    void close() override { closed = true; }
};
}
// The host rejects output creation. These link substitutes must never run;
// control validation and lifecycle can be tested without a decoder or Dart SDK.
extern "C" void airplay_player_destroy(AirplayPlayer* player) { if (player) std::abort(); }
extern "C" uint16_t airplay_player_port(AirplayPlayer*) { std::abort(); }
extern "C" size_t airplay_player_txt(AirplayPlayer*, bool, uint8_t*, size_t) { std::abort(); }
extern "C" bool airplay_player_prepare_restart(AirplayPlayer*) { std::abort(); }
extern "C" void airplay_player_set_stats_enabled(AirplayPlayer*, bool) { std::abort(); }
extern "C" bool airplay_player_set_playback_buffer(AirplayPlayer*, int) { std::abort(); }
extern "C" bool airplay_player_set_fast_pairing(AirplayPlayer*, bool) { std::abort(); }
extern "C" bool airplay_player_set_volume(AirplayPlayer*, float) { std::abort(); }
extern "C" bool airplay_player_set_video_size(AirplayPlayer*, int, int) { std::abort(); }
extern "C" bool airplay_player_start(AirplayPlayer*, const char*, const uint8_t[6], const char*, char*, size_t) { std::abort(); }
int main() {
    try {
        const std::string json = R"({"C:\\key":"C:\\Users\\test\\pairing.pem","nested":[{"name":"Receiver\\TV\"\n\t\u0001"}],"integer":1234567890123,"negative":-15,"real":-7.5,"flag":true,"empty":null})";
        auto original = airplay::parse_json(json.c_str());
        airplay::set(original.get(), "textureId", int64_t(-1));
        auto restored = airplay::parse_json(airplay::json_text(original.get()).c_str());
        require(airplay::text(restored.get(), "C:\\key") == "C:\\Users\\test\\pairing.pem", "JSON paths and keys round-trip without losing backslashes");
        require(airplay::text(plist_array_get_item(airplay::item(restored.get(), "nested"), 0), "name") == "Receiver\\TV\"\n\t\x01", "nested JSON strings preserve quotes and controls");
        uint64_t integer = 0; plist_get_uint_val(airplay::item(restored.get(), "integer"), &integer);
        require(integer == 1234567890123 && airplay::integer(restored.get(), "negative") == -15 && airplay::integer(restored.get(), "textureId") == -1, "JSON keeps positive and negative integers");
        auto bytes = airplay::json_object();
        // Truncated, overlong, surrogate and out-of-range sequences are replaced.
        airplay::set(bytes.get(), "name", std::string("iPhone \xe4\xbd\xa0\xe5 \xc0\xaf \xed\xa0\x80 \xf4\x90\x80\x80 \xf0\x9f\x93\xba"));
        const auto encoded = airplay::json_text(bytes.get());
        require(encoded == "{\"name\":\"iPhone \xe4\xbd\xa0\xef\xbf\xbd \xef\xbf\xbd\xef\xbf\xbd \xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd \xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd \xf0\x9f\x93\xba\"}",
                "JSON replaces invalid UTF-8 and keeps valid characters");
        double real = 0; plist_get_real_val(airplay::item(restored.get(), "real"), &real);
        require(real == -7.5 && airplay::boolean(restored.get(), "flag") && plist_get_node_type(airplay::item(restored.get(), "empty")) == PLIST_NULL, "JSON keeps real, boolean and null values");
    } catch (const std::exception& error) { require(false, error.what()); }
    AirplayReceiverHost host{};
    host.create_player = [](void*, AirplayCallbacks, int, int, int, char* error, size_t capacity) -> AirplayPlayer* {
        snprintf(error, capacity, "Synthetic output failure"); return nullptr;
    };
    const uint8_t identity[6]{2,0,0,0,0,1}; char error[512]{};
    const auto handle = airplay_receiver_create(host, "{\"defaultName\":\"Fixture\"}", "unused", identity, error, sizeof(error));
    require(handle != 0, "control creates without a transport");
    auto observer = std::make_shared<Observer>();
    require(airplay::observe_receiver(handle, observer), "adapter subscribes to copied events");
    AirplayReceiverSettings settings{};
    settings.fields = AIRPLAY_SETTING_NAME; settings.name = "New name"; settings.name_size = 8;
    require(airplay_receiver_save(handle, &settings, error, sizeof(error)), "settings applied on worker");
    settings.name = "bad\0name";
    require(!airplay_receiver_save(handle, &settings, error, sizeof(error)), "invalid name rejected");
    auto* snapshot = airplay_receiver_snapshot(handle, error, sizeof(error));
    require(snapshot && std::string(snapshot->settings.name) == "New name", "failed settings retain desired value");
    airplay_receiver_free_snapshot(snapshot);
    settings.fields = AIRPLAY_SETTING_PLAYBACK_BUFFER;
    for (int value : {0, 40, 60, 80, 100, 120, 150, 200, 300}) {
        settings.playback_buffer_ms = value;
        require(airplay_receiver_save(handle, &settings, error, sizeof(error)), "buffer preset accepted");
        snapshot = airplay_receiver_snapshot(handle, error, sizeof(error));
        require(snapshot && snapshot->settings.playback_buffer_ms == value, "typed snapshot retains buffer");
        airplay_receiver_free_snapshot(snapshot);
    }
    for (int value : {-1, 90, 301}) {
        settings.playback_buffer_ms = value;
        require(!airplay_receiver_save(handle, &settings, error, sizeof(error)), "invalid buffer rejected");
    }
    snapshot = airplay_receiver_snapshot(handle, error, sizeof(error));
    require(snapshot && snapshot->settings.playback_buffer_ms == 300, "invalid buffer retains previous value");
    airplay_receiver_free_snapshot(snapshot);
    require(!airplay_receiver_start(handle, UINT64_MAX, error, sizeof(error)), "output failure reaches control caller");
    snapshot = airplay_receiver_snapshot(handle, error, sizeof(error));
    require(snapshot && snapshot->status == AIRPLAY_RECEIVER_ERROR && !snapshot->pid, "startup failure cleans runtime");
    airplay_receiver_free_snapshot(snapshot);
    require(airplay_receiver_stop(handle, error, sizeof(error)), "stop recovers failed receiver");
    airplay_receiver_log(handle, "Fixture log");
    auto requested = airplay::control_receiver(handle, R"({"method":"snapshot"})");
    require(plist_array_get_size(airplay::item(requested.get(), "logs")) > 0, "requested snapshots include log history");
    airplay_receiver_destroy(handle);
    require(observer->closed && !observer->events.empty(), "worker drains events before closing outlet");
    bool snapshots = false;
    for (const auto& bytes : observer->events) {
        auto event = airplay::parse_json(bytes.c_str());
        if (airplay::text(event.get(), "type") != "snapshot") continue;
        snapshots = true;
        require(!airplay::item(airplay::item(event.get(), "data"), "logs"), "state-change snapshots omit log history");
    }
    require(snapshots, "state changes publish snapshots");
    require(!airplay::observe_receiver(handle, observer), "stale handle cannot acquire an outlet");
    require(!airplay_receiver_stop(handle, error, sizeof(error)), "stale operation is rejected");
    puts("PASS: receiver control without Dart, protocol or media backends");
}
