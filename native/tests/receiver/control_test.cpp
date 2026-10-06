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
extern "C" bool airplay_player_set_fast_pairing(AirplayPlayer*, bool) { std::abort(); }
extern "C" bool airplay_player_set_video_size(AirplayPlayer*, int, int) { std::abort(); }
extern "C" bool airplay_player_start(AirplayPlayer*, const char*, const uint8_t[6], const char*, char*, size_t) { std::abort(); }
int main() {
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
    require(!airplay_receiver_start(handle, UINT64_MAX, error, sizeof(error)), "output failure reaches control caller");
    snapshot = airplay_receiver_snapshot(handle, error, sizeof(error));
    require(snapshot && snapshot->status == AIRPLAY_RECEIVER_ERROR && !snapshot->pid, "startup failure cleans runtime");
    airplay_receiver_free_snapshot(snapshot);
    require(airplay_receiver_stop(handle, error, sizeof(error)), "stop recovers failed receiver");
    airplay_receiver_destroy(handle);
    require(observer->closed && !observer->events.empty(), "worker drains events before closing outlet");
    require(!airplay::observe_receiver(handle, observer), "stale handle cannot acquire an outlet");
    require(!airplay_receiver_stop(handle, error, sizeof(error)), "stale operation is rejected");
    puts("PASS: receiver control without Dart, protocol or media backends");
}
