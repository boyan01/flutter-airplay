// SPDX-License-Identifier: GPL-3.0-only
#include "../include/airplay/receiver.h"
#include "json.h"
#include "../playback/video_quality.h"
#include "receiver_internal.h"
#include <array>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <future>
#include <map>
#include <mutex>
#include <thread>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#include <process.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace {
using namespace airplay;
struct Settings {
    uint32_t fields = AIRPLAY_SETTINGS_ALL;
    std::string name, path;
    AirplayVideoQuality video_quality = AIRPLAY_VIDEO_AUTO;
    AirplayAudioOutput audio_output = AIRPLAY_AUDIO_AUTO;
    int playback_buffer_ms = 0;
    bool auto_start = true, fast_pairing = true, launch_at_login = false, keep_in_menu_bar = true;
    bool show_on_connect = true, fullscreen_on_connect = false, always_on_top = false, show_playback_stats = false;
    void apply(const Settings& patch) {
        if (patch.fields & AIRPLAY_SETTING_NAME) name = patch.name;
        if (patch.fields & AIRPLAY_SETTING_PATH) path = patch.path;
        if (patch.fields & AIRPLAY_SETTING_VIDEO_QUALITY) video_quality = patch.video_quality;
        if (patch.fields & AIRPLAY_SETTING_AUDIO_OUTPUT) audio_output = patch.audio_output;
        if (patch.fields & AIRPLAY_SETTING_AUTO_START) auto_start = patch.auto_start;
        if (patch.fields & AIRPLAY_SETTING_FAST_PAIRING) fast_pairing = patch.fast_pairing;
        if (patch.fields & AIRPLAY_SETTING_LAUNCH_AT_LOGIN) launch_at_login = patch.launch_at_login;
        if (patch.fields & AIRPLAY_SETTING_KEEP_IN_MENU_BAR) keep_in_menu_bar = patch.keep_in_menu_bar;
        if (patch.fields & AIRPLAY_SETTING_SHOW_ON_CONNECT) show_on_connect = patch.show_on_connect;
        if (patch.fields & AIRPLAY_SETTING_FULLSCREEN_ON_CONNECT) fullscreen_on_connect = patch.fullscreen_on_connect;
        if (patch.fields & AIRPLAY_SETTING_ALWAYS_ON_TOP) always_on_top = patch.always_on_top;
        if (patch.fields & AIRPLAY_SETTING_PLAYBACK_STATS) show_playback_stats = patch.show_playback_stats;
        if (patch.fields & AIRPLAY_SETTING_PLAYBACK_BUFFER) playback_buffer_ms = patch.playback_buffer_ms;
    }
};
const char* status_name(AirplayReceiverStatus status) {
    constexpr const char* names[] = {"stopped", "starting", "waiting", "streaming", "stopping", "error"};
    return names[status];
}

std::string timestamp() {
    const auto now = std::chrono::system_clock::now();
    const auto clock = std::chrono::system_clock::to_time_t(now);
    std::tm utc{};
#ifdef _WIN32
    gmtime_s(&utc, &clock);
#else
    gmtime_r(&clock, &utc);
#endif
    char bytes[32]; strftime(bytes, sizeof(bytes), "%Y-%m-%dT%H:%M:%SZ", &utc); return bytes;
}
std::string trim(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    return first == std::string::npos ? "" : value.substr(first, value.find_last_not_of(" \t\r\n") - first + 1);
}
bool valid_name(const std::string& name) {
    if (name.empty() || name.size() > 50) return false;
    // Validate UTF-8 and reject Unicode C0/C1 controls, without a platform codec.
    for (size_t i = 0; i < name.size();) {
        uint32_t c = uint8_t(name[i++]); int remaining = 0; uint32_t minimum = 0;
        if (c >= 0xc2 && c <= 0xdf) { c &= 31; remaining = 1; minimum = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { c &= 15; remaining = 2; minimum = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { c &= 7; remaining = 3; minimum = 0x10000; }
        else if (c >= 0x80) return false;
        for (int j = 0; j < remaining; ++j) {
            if (i == name.size() || (uint8_t(name[i]) & 0xc0) != 0x80) return false;
            c = (c << 6) | (uint8_t(name[i++]) & 63);
        }
        if (c < minimum || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff) || c < 32 || (c >= 127 && c <= 159)) return false;
    }
    return true;
}

std::string default_name(const std::string& device) {
    std::string clean;
    for (size_t i = 0; i < device.size();) {
        const auto lead = uint8_t(device[i]);
        const size_t size = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
        const auto character = device.substr(i, size);
        if (!valid_name(character)) { ++i; continue; }
        if (clean.size() + size > 50) break;
        clean += character; i += size;
    }
    clean = trim(clean);
    return clean.empty() ? "Flutter AirPlay" : clean;
}

AirplayReceiverSnapshot* metadata_snapshot(plist_t value);
char* owned_text(const std::string& value);
std::string copied_text(const char* bytes, size_t size) {
    if (size > 1024 * 1024 || (!bytes && size)) throw std::runtime_error("Invalid receiver string");
    return bytes ? std::string(bytes, size) : "";
}
const char* quality_name(int value) {
    if (value < AIRPLAY_VIDEO_AUTO || value > AIRPLAY_VIDEO_2160) throw std::runtime_error("Unknown video quality");
    return video_qualities[size_t(value)];
}
const char* audio_name(int value) {
    switch (value) { case AIRPLAY_AUDIO_AUTO: return "auto"; case AIRPLAY_AUDIO_AAUDIO: return "aaudio";
        case AIRPLAY_AUDIO_AUDIOTRACK: return "audiotrack"; default: throw std::runtime_error("Invalid audio output selection"); }
}
bool valid_playback_buffer(int64_t value) {
    return value == 0 || value == 40 || value == 60 || value == 80 || value == 100 ||
        value == 120 || value == 150 || value == 200 || value == 300;
}
Settings copied_settings(const AirplayReceiverSettings& value) {
    if (value.fields & ~uint32_t(AIRPLAY_SETTINGS_ALL)) throw std::runtime_error("Invalid settings fields");
    Settings result; result.fields = value.fields;
    if (value.fields & AIRPLAY_SETTING_NAME) result.name = copied_text(value.name, value.name_size);
    if (value.fields & AIRPLAY_SETTING_PATH) result.path = copied_text(value.path, value.path_size);
    if (value.fields & AIRPLAY_SETTING_VIDEO_QUALITY) result.video_quality = AirplayVideoQuality(value.video_quality);
    if (value.fields & AIRPLAY_SETTING_AUDIO_OUTPUT) result.audio_output = AirplayAudioOutput(value.audio_output);
    if (value.fields & AIRPLAY_SETTING_AUTO_START) result.auto_start = value.auto_start;
    if (value.fields & AIRPLAY_SETTING_FAST_PAIRING) result.fast_pairing = value.fast_pairing;
    if (value.fields & AIRPLAY_SETTING_LAUNCH_AT_LOGIN) result.launch_at_login = value.launch_at_login;
    if (value.fields & AIRPLAY_SETTING_KEEP_IN_MENU_BAR) result.keep_in_menu_bar = value.keep_in_menu_bar;
    if (value.fields & AIRPLAY_SETTING_SHOW_ON_CONNECT) result.show_on_connect = value.show_on_connect;
    if (value.fields & AIRPLAY_SETTING_FULLSCREEN_ON_CONNECT) result.fullscreen_on_connect = value.fullscreen_on_connect;
    if (value.fields & AIRPLAY_SETTING_ALWAYS_ON_TOP) result.always_on_top = value.always_on_top;
    if (value.fields & AIRPLAY_SETTING_PLAYBACK_STATS) result.show_playback_stats = value.show_playback_stats;
    if (value.fields & AIRPLAY_SETTING_PLAYBACK_BUFFER) {
        if (!valid_playback_buffer(value.playback_buffer_ms)) throw std::runtime_error("Invalid playback buffer");
        result.playback_buffer_ms = value.playback_buffer_ms;
    }
    if (value.fields & AIRPLAY_SETTING_NAME) {
        result.name = trim(result.name);
        if (!valid_name(result.name)) throw std::runtime_error("Invalid receiver name");
    }
    if (value.fields & AIRPLAY_SETTING_PATH) {
        result.path = trim(result.path);
        if (!result.path.empty()) throw std::runtime_error("Playback uses the built-in receiver core");
    }
    if (value.fields & AIRPLAY_SETTING_VIDEO_QUALITY) quality_name(result.video_quality);
    if (value.fields & AIRPLAY_SETTING_AUDIO_OUTPUT) audio_name(result.audio_output);
    return result;
}
Settings settings_from_json(plist_t value) {
    if (plist_get_node_type(value) != PLIST_DICT) throw std::runtime_error("Missing receiver settings");
    Settings result; result.fields = 0;
    auto string_field = [&](const char* key, uint32_t field, std::string& target) {
        if (auto node = item(value, key)) {
            if (plist_get_node_type(node) != PLIST_STRING) throw std::runtime_error(std::string("Invalid setting: ") + key);
            target = trim(text(value, key)); result.fields |= field;
        }
    };
    string_field("name", AIRPLAY_SETTING_NAME, result.name);
    string_field("path", AIRPLAY_SETTING_PATH, result.path);
    if (auto node = item(value, "videoQuality")) {
        if (plist_get_node_type(node) != PLIST_STRING) throw std::runtime_error("Unknown video quality");
        const auto quality = text(value, "videoQuality");
        auto found = std::find(video_qualities.begin(), video_qualities.end(), quality);
        if (found == video_qualities.end()) throw std::runtime_error("Unknown video quality");
        result.video_quality = AirplayVideoQuality(found - video_qualities.begin()); result.fields |= AIRPLAY_SETTING_VIDEO_QUALITY;
    }
    if (auto node = item(value, "audioOutput")) {
        const auto output = text(value, "audioOutput");
        if (plist_get_node_type(node) != PLIST_STRING || (output != "auto" && output != "aaudio" && output != "audiotrack"))
            throw std::runtime_error("Invalid audio output selection");
        result.audio_output = output == "auto" ? AIRPLAY_AUDIO_AUTO : output == "aaudio" ? AIRPLAY_AUDIO_AAUDIO : AIRPLAY_AUDIO_AUDIOTRACK;
        result.fields |= AIRPLAY_SETTING_AUDIO_OUTPUT;
    }
    if (auto node = item(value, "playbackBufferMs")) {
        const auto buffer = integer(value, "playbackBufferMs", -1);
        if (plist_get_node_type(node) != PLIST_UINT || !valid_playback_buffer(buffer))
            throw std::runtime_error("Invalid playback buffer");
        result.playback_buffer_ms = int(buffer); result.fields |= AIRPLAY_SETTING_PLAYBACK_BUFFER;
    }
    auto bool_field = [&](const char* key, uint32_t field, bool& target) {
        if (auto node = item(value, key)) {
            if (plist_get_node_type(node) != PLIST_BOOLEAN) throw std::runtime_error(std::string("Invalid setting: ") + key);
            target = boolean(value, key); result.fields |= field;
        }
    };
    bool_field("autoStart", AIRPLAY_SETTING_AUTO_START, result.auto_start);
    bool_field("fastPairing", AIRPLAY_SETTING_FAST_PAIRING, result.fast_pairing);
    bool_field("launchAtLogin", AIRPLAY_SETTING_LAUNCH_AT_LOGIN, result.launch_at_login);
    bool_field("keepInMenuBar", AIRPLAY_SETTING_KEEP_IN_MENU_BAR, result.keep_in_menu_bar);
    bool_field("showOnConnect", AIRPLAY_SETTING_SHOW_ON_CONNECT, result.show_on_connect);
    bool_field("fullscreenOnConnect", AIRPLAY_SETTING_FULLSCREEN_ON_CONNECT, result.fullscreen_on_connect);
    bool_field("alwaysOnTop", AIRPLAY_SETTING_ALWAYS_ON_TOP, result.always_on_top);
    bool_field("showPlaybackStats", AIRPLAY_SETTING_PLAYBACK_STATS, result.show_playback_stats);
    return result;
}
Json settings_json(const Settings& value) {
    auto result = json_object();
    if (value.fields & AIRPLAY_SETTING_NAME) set(result.get(), "name", value.name);
    if (value.fields & AIRPLAY_SETTING_PATH) set(result.get(), "path", value.path);
    if (value.fields & AIRPLAY_SETTING_VIDEO_QUALITY) set(result.get(), "videoQuality", quality_name(value.video_quality));
    if (value.fields & AIRPLAY_SETTING_AUDIO_OUTPUT) set(result.get(), "audioOutput", audio_name(value.audio_output));
    if (value.fields & AIRPLAY_SETTING_AUTO_START) set(result.get(), "autoStart", value.auto_start);
    if (value.fields & AIRPLAY_SETTING_FAST_PAIRING) set(result.get(), "fastPairing", value.fast_pairing);
    if (value.fields & AIRPLAY_SETTING_LAUNCH_AT_LOGIN) set(result.get(), "launchAtLogin", value.launch_at_login);
    if (value.fields & AIRPLAY_SETTING_KEEP_IN_MENU_BAR) set(result.get(), "keepInMenuBar", value.keep_in_menu_bar);
    if (value.fields & AIRPLAY_SETTING_SHOW_ON_CONNECT) set(result.get(), "showOnConnect", value.show_on_connect);
    if (value.fields & AIRPLAY_SETTING_FULLSCREEN_ON_CONNECT) set(result.get(), "fullscreenOnConnect", value.fullscreen_on_connect);
    if (value.fields & AIRPLAY_SETTING_ALWAYS_ON_TOP) set(result.get(), "alwaysOnTop", value.always_on_top);
    if (value.fields & AIRPLAY_SETTING_PLAYBACK_STATS) set(result.get(), "showPlaybackStats", value.show_playback_stats);
    if (value.fields & AIRPLAY_SETTING_PLAYBACK_BUFFER) set(result.get(), "playbackBufferMs", int64_t(value.playback_buffer_ms));
    return result;
}
void fill_settings(AirplayReceiverSettings& out, const Settings& value) {
    out.fields = value.fields;
    if (value.fields & AIRPLAY_SETTING_NAME) { out.name = owned_text(value.name); out.name_size = value.name.size(); }
    if (value.fields & AIRPLAY_SETTING_PATH) { out.path = owned_text(value.path); out.path_size = value.path.size(); }
    if (value.fields & AIRPLAY_SETTING_VIDEO_QUALITY) out.video_quality = value.video_quality;
    if (value.fields & AIRPLAY_SETTING_AUDIO_OUTPUT) out.audio_output = value.audio_output;
    if (value.fields & AIRPLAY_SETTING_AUTO_START) out.auto_start = value.auto_start;
    if (value.fields & AIRPLAY_SETTING_FAST_PAIRING) out.fast_pairing = value.fast_pairing;
    if (value.fields & AIRPLAY_SETTING_LAUNCH_AT_LOGIN) out.launch_at_login = value.launch_at_login;
    if (value.fields & AIRPLAY_SETTING_KEEP_IN_MENU_BAR) out.keep_in_menu_bar = value.keep_in_menu_bar;
    if (value.fields & AIRPLAY_SETTING_SHOW_ON_CONNECT) out.show_on_connect = value.show_on_connect;
    if (value.fields & AIRPLAY_SETTING_FULLSCREEN_ON_CONNECT) out.fullscreen_on_connect = value.fullscreen_on_connect;
    if (value.fields & AIRPLAY_SETTING_ALWAYS_ON_TOP) out.always_on_top = value.always_on_top;
    if (value.fields & AIRPLAY_SETTING_PLAYBACK_STATS) out.show_playback_stats = value.show_playback_stats;
    if (value.fields & AIRPLAY_SETTING_PLAYBACK_BUFFER) out.playback_buffer_ms = value.playback_buffer_ms;
}

class Receiver;
thread_local Receiver* worker_receiver = nullptr;

class Receiver : public std::enable_shared_from_this<Receiver> {
public:
    AirplayReceiverHost host;
    uint64_t handle = 0;
    Receiver(AirplayReceiverHost hooks, const char *metadata,
             const char *key, const uint8_t *id)
        : host(hooks), metadata_(parse_json(metadata)),
          key_(key) {
        std::copy_n(id, 6, identity_.begin());
        set(metadata_.get(), "defaultName", default_name(text(metadata_.get(), "defaultName")));
        if (!item(metadata_.get(), "videoQualities")) {
            auto* qualities = plist_new_array();
            for (auto quality : video_qualities) plist_array_append_item(qualities, plist_new_string(quality));
            plist_dict_set_item(metadata_.get(), "videoQualities", qualities);
        }
        settings_.name = text(metadata_.get(), "defaultName");
        active_.fields = 0;
        validate(settings_);
        foreground_ = boolean(metadata_.get(), "foreground", true);
    }
    ~Receiver() { close(); }
    bool observe(std::shared_ptr<ReceiverObserver> observer) {
        std::lock_guard<std::mutex> guard(event_lock_);
        if (events_closed_ || observer_) return false;
        observer_ = std::move(observer); return true;
    }
    void launch() { worker_ = std::thread([this] { run(); }); }
    bool enqueue(std::function<void()> task) {
        std::lock_guard<std::mutex> guard(lock_);
        if (closing_) return false;
        tasks_.push_back(std::move(task)); wake_.notify_one(); return true;
    }
    template<class F> auto sync(F action) -> decltype(action()) {
        if (std::this_thread::get_id() == worker_.get_id()) return action();
        auto task = std::make_shared<std::packaged_task<decltype(action())()>>(std::move(action));
        auto result = task->get_future();
        if (!enqueue([task] { (*task)(); })) throw std::runtime_error("Receiver has closed");
        return result.get();
    }
    void close() {
        { std::lock_guard<std::mutex> guard(lock_); closing_ = true; wake_.notify_all(); }
        if (worker_.joinable()) worker_.join();
    }
    AirplayReceiverSnapshot* read_snapshot() {
        std::unique_ptr<AirplayReceiverSnapshot, decltype(&airplay_receiver_free_snapshot)> out(metadata_snapshot(metadata_.get()), airplay_receiver_free_snapshot);
        fill_settings(out->settings, settings_); fill_settings(out->active_settings, active_);
        out->status = status_;
        out->message = owned_text(message_); out->client_name = owned_text(client_); out->receiving_name = owned_text(receiving_name_);
        out->video_width = width_; out->video_height = height_; out->generation = generation_;
        out->texture_id = host.texture_id ? host.texture_id(host.context) : int64_t(-1);
        out->pid = player_ ? int64_t(
#ifdef _WIN32
            _getpid()
#else
            getpid()
#endif
        ) : 0;
        out->audio_playing = audio_; out->video_paused = paused_;
        out->log_count = logs_.size();
        auto* entries = static_cast<AirplayReceiverLog*>(calloc(out->log_count, sizeof(AirplayReceiverLog)));
        if (out->log_count && !entries) throw std::bad_alloc();
        out->logs = entries;
        for (size_t i = 0; i < logs_.size(); ++i) {
            entries[i].id = logs_[i].id; entries[i].time = owned_text(logs_[i].time); entries[i].text = owned_text(logs_[i].text);
        }
        return out.release();
    }
    void configure(const Settings& settings) { save(settings); }
    void begin(uint64_t expected_generation) {
        if (expected_generation != UINT64_MAX && expected_generation != generation_)
            throw std::runtime_error("Receiver startup was cancelled");
        start();
    }
    void end() { resume_ = false; stop(); }
    void disconnect() { stop(true); start(); }
    bool apply_settings() {
        if ((!foreground_only() || foreground_) && status_ == AIRPLAY_RECEIVER_WAITING && player_ && airplay_player_prepare_restart(player_)) {
            stop(true); start(); return true;
        }
        return false;
    }
    void suspend() { resume_ = resume_ || player_ != nullptr; foreground_ = false; stop(); }
    void resume() { foreground_ = true; if (resume_) { start(); resume_ = false; } }
    void check(const std::string& path) {
        if (!trim(path).empty()) throw std::runtime_error("Playback uses the built-in receiver core");
        char error[512]{};
        if (host.check && !host.check(host.context, error, sizeof(error))) throw std::runtime_error(error);
        log("Built-in C++ receiver and platform playback adapters are loaded.");
    }
    Json control(plist_t request) {
        const auto method = text(request, "method");
        const auto arguments = item(request, "arguments");
        if (arguments && plist_get_node_type(arguments) != PLIST_DICT) throw std::runtime_error("Invalid receiver arguments");
        if (method == "snapshot") return snapshot();
        auto result = json_object();
        if (method == "save") configure(settings_from_json(arguments));
        else if (method == "start") {
            const auto generation = item(arguments, "generation");
            if (plist_get_node_type(generation) != PLIST_UINT) throw std::runtime_error("Missing receiver generation");
            begin(uint64_t(integer(arguments, "generation")));
        } else if (method == "stop") end();
        else if (method == "disconnect") disconnect();
        else if (method == "applySettings") set(result.get(), "applied", apply_settings());
        else if (method == "check") {
            if (plist_get_node_type(item(arguments, "path")) != PLIST_STRING) throw std::runtime_error("Missing receiver path");
            check(text(arguments, "path"));
        } else throw std::runtime_error("Unknown receiver command: " + method);
        return result;
    }
    AirplayVideoSize requested_video_size() { const auto height = video_height(); return {requested_video_width(height), height}; }
    void request_start() { auto event = json_object(); set(event.get(), "type", "startRequest"); deliver(event.get()); }
    void request_settings(const Settings& settings) {
        auto event = json_object(); set(event.get(), "type", "settingsRequest");
        plist_dict_set_item(event.get(), "settings", settings_json(settings).release()); deliver(event.get());
    }
    void output_error(std::string message) {
        const auto epoch = generation_.load();
        enqueue([this, epoch, message = std::move(message)] {
            if (player_ && epoch == generation_) fail(message);
        });
    }
    void update(std::string json) {
        enqueue([this, json = std::move(json)] { try {
            auto value = parse_json(json.c_str());
            if (item(value.get(), "defaultName")) set(value.get(), "defaultName", default_name(text(value.get(), "defaultName")));
            if (auto foreground = item(value.get(), "foreground")) foreground_ = boolean(value.get(), "foreground", true);
            Json next(plist_copy(metadata_.get())); merge(next.get(), value.get());
            if (json_text(next.get()) != json_text(metadata_.get())) { metadata_ = std::move(next); changed(); }
        }
            catch (const std::exception& error) { log(error.what()); } });
    }
    void discovery(uint64_t epoch, bool ready, std::string error, std::string name) {
        enqueue([this, epoch, ready, error = std::move(error), name = std::move(name)] {
            if (!player_ || epoch != generation_) return;
            if (!ready) { fail(error.empty() ? "Discovery registration failed" : error); return; }
            if (!name.empty()) { receiving_name_ = name; changed(); }
            if (status_ == AIRPLAY_RECEIVER_STARTING) state(AIRPLAY_RECEIVER_WAITING, "等待 iPhone · 请在控制中心选择此设备");
        });
    }
    bool surface(void *surface) {
        return sync([this, surface] { return host.set_surface ? host.set_surface(host.context, player_, surface) : !player_; });
    }
    void log(const std::string& bytes) {
        auto entry = json_object(); set(entry.get(), "id", ++log_id_); set(entry.get(), "time", timestamp());
        size_t length = std::min<size_t>(bytes.size(), 4096);
        if (length < bytes.size()) while (length && (uint8_t(bytes[length]) & 0xc0) == 0x80) --length;
        auto clean = bytes.substr(0, length);
        set(entry.get(), "text", clean);
        logs_.push_back({log_id_, text(entry.get(), "time"), clean}); if (logs_.size() > 300) logs_.pop_front();
        auto event = json_object(); set(event.get(), "type", "log"); plist_dict_set_item(event.get(), "entry", entry.release()); deliver(event.get());
    }
private:
    std::mutex event_lock_;
    std::shared_ptr<ReceiverObserver> observer_;
    bool events_closed_ = false;
    Json metadata_;
    Settings settings_, active_;
    std::string key_, receiving_name_, client_, message_ = "接收器未启动";
    AirplayReceiverStatus status_ = AIRPLAY_RECEIVER_STOPPED;
    std::array<uint8_t, 6> identity_{};
    struct Log { int64_t id; std::string time, text; };
    std::deque<Log> logs_;
    int64_t log_id_ = 0;
    int width_ = 0, height_ = 0;
    int64_t last_texture_ = -1;
    bool audio_ = false, paused_ = false, foreground_ = true, resume_ = false;
    std::atomic<uint64_t> generation_{0};
    AirplayPlayer *player_ = nullptr;
    struct Callback { Receiver *owner; uint64_t generation; };
    std::unique_ptr<Callback> callback_;
    std::mutex lock_;
    std::condition_variable wake_;
    std::deque<std::function<void()>> tasks_;
    std::thread worker_;
    bool closing_ = false;

    void report_output() {
        if (!host.diagnostics) return;
        char report[4096]{};
        host.diagnostics(host.context, report, sizeof(report));
        report[sizeof(report) - 1] = 0;
        if (report[0]) log(report);
    }
    void run() {
        worker_receiver = this;
        auto next_report = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        for (;;) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> guard(lock_);
                wake_.wait_until(guard, next_report, [this] { return closing_ || !tasks_.empty(); });
                if (tasks_.empty() && closing_) break;
                if (!tasks_.empty()) { task = std::move(tasks_.front()); tasks_.pop_front(); }
            }
            try {
                if (task) task();
                if (std::chrono::steady_clock::now() >= next_report) {
                    next_report = std::chrono::steady_clock::now() + std::chrono::seconds(5);
                    if (player_) report_output();
                }
            } catch (const std::exception& error) { log(error.what()); }
        }
        stop();
        { std::lock_guard<std::mutex> guard(event_lock_);
          events_closed_ = true;
          if (observer_) observer_->close();
          observer_.reset(); }
        worker_receiver = nullptr;
    }
    void deliver(plist_t message) {
        const auto bytes = json_text(message);
        if (host.event) host.event(host.context, bytes.c_str());
        std::lock_guard<std::mutex> guard(event_lock_);
        if (observer_) observer_->deliver(bytes);
    }

    Json snapshot() {
        Json value(plist_copy(metadata_.get())); merge(value.get(), settings_json(settings_).get());
        set(value.get(), "status", status_name(status_)); set(value.get(), "message", message_);
        set(value.get(), "clientName", client_); set(value.get(), "receivingName", receiving_name_);
        set(value.get(), "textureId", host.texture_id ? host.texture_id(host.context) : int64_t(-1));
        set(value.get(), "videoWidth", int64_t(width_)); set(value.get(), "videoHeight", int64_t(height_));
        set(value.get(), "audioPlaying", audio_); set(value.get(), "videoPaused", paused_);
        set(value.get(), "generation", int64_t(generation_.load()));
        set(value.get(), "pid", player_ ? int64_t(
#ifdef _WIN32
            _getpid()
#else
            getpid()
#endif
        ) : int64_t(0));
        plist_dict_set_item(value.get(), "activeSettings", settings_json(active_).release());
        auto logs = plist_new_array(); for (const auto& entry : logs_) {
            auto value = json_object(); set(value.get(), "id", entry.id); set(value.get(), "time", entry.time); set(value.get(), "text", entry.text);
            plist_array_append_item(logs, value.release());
        }
        plist_dict_set_item(value.get(), "logs", logs); return value;
    }
    void changed() {
        auto event = json_object(); set(event.get(), "type", "snapshot");
        plist_dict_set_item(event.get(), "data", snapshot().release()); deliver(event.get());
    }
    void state(AirplayReceiverStatus next, const std::string& detail) {
        if (status_ == next && message_ == detail) return;
        status_ = next; message_ = detail;
        if (status_ == AIRPLAY_RECEIVER_WAITING || status_ == AIRPLAY_RECEIVER_STOPPING || status_ == AIRPLAY_RECEIVER_STOPPED || status_ == AIRPLAY_RECEIVER_ERROR) {
            client_.clear(); width_ = height_ = 0; audio_ = paused_ = false;
        }
        changed();
    }
    void validate(const Settings& value) {
        if (!valid_name(value.name)) throw std::runtime_error("Invalid receiver name");
        if (!value.path.empty()) throw std::runtime_error("Playback uses the built-in receiver core");
        const auto quality = std::string(quality_name(value.video_quality));
        audio_name(value.audio_output);
        auto qualities = item(metadata_.get(), "videoQualities");
        if (qualities && value.video_quality != AIRPLAY_VIDEO_AUTO) {
            bool found = false;
            for (uint32_t i = 0; i < plist_array_get_size(qualities); ++i) {
                char *name = nullptr; plist_get_string_val(plist_array_get_item(qualities, i), &name);
                found |= name && quality == name; free(name);
            }
            if (!found) throw std::runtime_error("The decoder does not support this video quality at 60 FPS");
        }
    }
    void save(const Settings& patch) {
        auto next = settings_; next.apply(patch);
        validate(next);
        char error[512]{};
        const auto bytes = json_text(settings_json(next).get());
        if (host.preferences && !host.preferences(host.context, bytes.c_str(), error, sizeof(error)))
            throw std::runtime_error(error[0] ? error : "Cannot update platform preferences");
        settings_ = std::move(next);
        if (player_) airplay_player_set_stats_enabled(player_, settings_.show_playback_stats);
        changed();
    }
    bool foreground_only() { return boolean(item(metadata_.get(), "capabilities"), "foregroundOnly", false); }
    int video_height() {
        const auto quality = std::string(quality_name(settings_.video_quality));
        auto height = requested_video_height(quality, int(integer(metadata_.get(), "screenHeight", 1080)));
        if (quality == "auto") height = std::min(height, int(integer(metadata_.get(), "autoVideoHeight", height)));
        return height;
    }
    void start() {
        if (player_) return;
        if (!foreground_ && foreground_only()) throw std::runtime_error("请在应用前台启动接收器。");
        state(AIRPLAY_RECEIVER_STARTING, "正在启动接收器…");
        const auto epoch = ++generation_;
        callback_ = std::make_unique<Callback>(Callback{this, epoch});
        AirplayCallbacks callbacks{}; callbacks.context = callback_.get();
        callbacks.frame = [](void *context, void *frame, int64_t deadline) {
            auto *current = static_cast<Callback *>(context); auto *self = current->owner;
            if (current->generation == self->generation_ && self->host.frame) self->host.frame(self->host.context, frame, deadline);
        };
        callbacks.event = [](void *context, const char *type, const char *detail, int w, int h) {
            auto *current = static_cast<Callback *>(context); auto *self = current->owner; const auto epoch = current->generation;
            std::string event(type ? type : ""), bytes(detail ? detail : "");
            self->enqueue([self, epoch, event = std::move(event), bytes = std::move(bytes), w, h] {
                if (self->player_ && epoch == self->generation_) self->receive(event, bytes, w, h);
            });
        };
        callbacks.log = [](void *context, int, const char *message) {
            auto *current = static_cast<Callback *>(context); auto *self = current->owner; const auto epoch = current->generation;
            std::string bytes(message ? message : "");
            self->enqueue([self, epoch, bytes = std::move(bytes)] { if (epoch == self->generation_) {
                self->log(bytes);
                if (bytes.find("Unsupported Windows") == 0 || bytes.find("Unavailable Windows") == 0) self->fail(bytes);
            } });
        };
        char error[512]{};
        try {
            const auto height = video_height(), width = requested_video_width(height);
            const auto mode = settings_.audio_output;
            if (!host.create_player) throw std::runtime_error("Native playback adapter is unavailable");
            player_ = host.create_player(host.context, callbacks, width, height, int(mode), error, sizeof(error));
            if (!player_) throw std::runtime_error(error[0] ? error : "Cannot create native player");
            airplay_player_set_stats_enabled(player_, settings_.show_playback_stats);
            if (!airplay_player_set_playback_buffer(player_, settings_.playback_buffer_ms) ||
                !airplay_player_set_fast_pairing(player_, settings_.fast_pairing) ||
                !airplay_player_set_video_size(player_, width, height)) throw std::runtime_error("Cannot configure native player");
            receiving_name_ = settings_.name; active_ = settings_;
            active_.fields = AIRPLAY_SETTING_NAME | AIRPLAY_SETTING_PATH | AIRPLAY_SETTING_VIDEO_QUALITY |
                AIRPLAY_SETTING_FAST_PAIRING | AIRPLAY_SETTING_PLAYBACK_BUFFER;
            auto capabilities = item(metadata_.get(), "capabilities");
            if (text(capabilities, "platform") == "android") active_.fields |= AIRPLAY_SETTING_AUDIO_OUTPUT;
            log("Receiver request: quality=" + std::string(quality_name(settings_.video_quality)) + ", " + std::to_string(width) + "x" + std::to_string(height) + ", maxFPS=60; sender chooses actual codec/size/rate");
            if (!airplay_player_start(player_, receiving_name_.c_str(), identity_.data(), key_.c_str(), error, sizeof(error)))
                throw std::runtime_error(error);
#ifndef _WIN32
            if (chmod(key_.c_str(), 0600)) throw std::runtime_error("Cannot secure the private AirPlay pairing key");
#endif
            int published = 1;
            if (host.publish) {
                std::vector<uint8_t> video(airplay_player_txt(player_, false, nullptr, 0)), audio(airplay_player_txt(player_, true, nullptr, 0));
                if (video.empty() || audio.empty()) throw std::runtime_error("Invalid discovery records");
                airplay_player_txt(player_, false, video.data(), video.size()); airplay_player_txt(player_, true, audio.data(), audio.size());
                published = host.publish(host.context, epoch, receiving_name_.c_str(), identity_.data(), airplay_player_port(player_),
                    video.data(), video.size(), audio.data(), audio.size(), error, sizeof(error));
                if (published < 0) throw std::runtime_error(error[0] ? error : "Cannot publish discovery services");
            }
            if (published) state(AIRPLAY_RECEIVER_WAITING, "等待 iPhone · 请在控制中心选择此设备"); else changed();
        } catch (const std::exception& failure) { fail(failure.what()); throw; }
    }
    void stop(bool restarting = false) {
        if (!player_ && !callback_) {
            ++generation_;
            if (host.end_video) host.end_video(host.context, restarting);
            if (!restarting) state(AIRPLAY_RECEIVER_STOPPED, "接收器已停止");
            return;
        }
        ++generation_; state(restarting ? AIRPLAY_RECEIVER_STARTING : AIRPLAY_RECEIVER_STOPPING, "正在停止接收器…");
        if (host.unpublish) host.unpublish(host.context);
        airplay_player_destroy(player_); player_ = nullptr; callback_.reset();
        report_output();
        if (host.end_video) host.end_video(host.context, restarting);
        if (!restarting) state(AIRPLAY_RECEIVER_STOPPED, "接收器已停止");
    }
    void fail(const std::string& error) { stop(); state(AIRPLAY_RECEIVER_ERROR, error); }
    void receive(const std::string& type, const std::string& detail, int width, int height) {
        if (type == "playbackStats") {
            if (settings_.show_playback_stats && width_ > 0 && !paused_) {
                auto event = json_object(); set(event.get(), "type", "playbackStats");
                plist_dict_set_item(event.get(), "metrics", parse_json(detail.c_str()).release()); deliver(event.get());
            }
        } else if (type == "client") { client_ = detail; state(AIRPLAY_RECEIVER_STREAMING, "已建立连接，等待第一帧画面"); changed(); }
        else if (type == "connecting") { if (!width_) state(AIRPLAY_RECEIVER_STREAMING, "已建立连接，等待第一帧画面"); }
        else if (type == "playing") {
            const auto texture = host.texture_id ? host.texture_id(host.context) : int64_t(-1);
            const bool different = width_ != width || height_ != height || paused_ || texture != last_texture_;
            last_texture_ = texture;
            width_ = width; height_ = height; paused_ = false;
            if (status_ != AIRPLAY_RECEIVER_STREAMING || message_ != "正在播放屏幕镜像") state(AIRPLAY_RECEIVER_STREAMING, "正在播放屏幕镜像");
            else if (different) changed();
        } else if (type == "waiting") { if (host.clear_video) host.clear_video(host.context); state(AIRPLAY_RECEIVER_WAITING, "连接已结束 · 等待下一次投屏"); }
        else if (type == "paused" || type == "reset") {
            paused_ = type == "paused"; if (!paused_) audio_ = false;
            width_ = height_ = 0; if (host.clear_video) host.clear_video(host.context);
            if (paused_) state(AIRPLAY_RECEIVER_STREAMING, "画面已暂停"); else changed();
        } else if (type == "audio" || type == "audio_stopped") {
            audio_ = type == "audio";
            if (audio_ && !width_) state(AIRPLAY_RECEIVER_STREAMING, "音频播放中"); else changed();
        } else if (type == "error") fail(detail);
    }
};

std::mutex registry_lock;
std::map<uint64_t, std::shared_ptr<Receiver>> receivers;
uint64_t next_handle = 0;
std::shared_ptr<Receiver> receiver(uint64_t handle) {
    if (worker_receiver && worker_receiver->handle == handle) return worker_receiver->shared_from_this();
    std::lock_guard<std::mutex> guard(registry_lock);
    auto found = receivers.find(handle); return found == receivers.end() ? nullptr : found->second;
}

char* owned_text(const std::string& value) {
    auto* result = static_cast<char*>(malloc(value.size() + 1));
    if (!result) throw std::bad_alloc();
    memcpy(result, value.c_str(), value.size() + 1); return result;
}
AirplayReceiverSnapshot* metadata_snapshot(plist_t value) {
    std::unique_ptr<AirplayReceiverSnapshot, decltype(&airplay_receiver_free_snapshot)> out(new AirplayReceiverSnapshot{}, airplay_receiver_free_snapshot);

    out->default_name = owned_text(text(value, "defaultName"));
    out->build_time = owned_text(text(value, "buildTime"));
    auto capabilities = item(value, "capabilities"); out->platform = owned_text(text(capabilities, "platform"));
    out->supports_executable_path = boolean(capabilities, "supportsExecutablePath");
    out->supports_launch_at_login = boolean(capabilities, "supportsLaunchAtLogin");
    out->supports_aac_eld = boolean(capabilities, "supportsAacEld");
    out->is_television = boolean(capabilities, "isTelevision");
    out->native_video_surface = boolean(capabilities, "nativeVideoSurface");
    out->foreground_only = boolean(capabilities, "foregroundOnly");
    out->screen_width = integer(value, "screenWidth", 1920);
    out->screen_height = integer(value, "screenHeight", 1080);
    out->auto_video_height = integer(value, "autoVideoHeight", 2160);
    auto qualities = item(value, "videoQualities");
    for (uint32_t i = 0; i < plist_array_get_size(qualities); ++i) {
        char* quality = nullptr; plist_get_string_val(plist_array_get_item(qualities, i), &quality);
        for (size_t j = 0; j < video_qualities.size(); ++j) if (quality && quality == std::string(video_qualities[j])) out->video_quality_mask |= 1u << j;
        free(quality);
    }
    return out.release();
}
template<class F> bool native_action(uint64_t handle, char* error, size_t capacity, F action) {
    try {
        auto value = receiver(handle); if (!value) throw std::runtime_error("Receiver has closed");
        value->sync([&] { action(*value); }); return true;
    } catch (const std::exception& failure) { if (error && capacity) snprintf(error, capacity, "%s", failure.what()); return false; }
}
}  // namespace

extern "C" uint64_t airplay_receiver_create(AirplayReceiverHost host, const char *metadata,
    const char *key, const uint8_t *identity, char *error, size_t capacity) {
    try {
        if (!key || !identity) throw std::runtime_error("Invalid native receiver configuration");
        auto value = std::make_shared<Receiver>(host, metadata, key, identity);
        std::lock_guard<std::mutex> guard(registry_lock);
        auto handle = ++next_handle; value->handle = handle; value->launch(); receivers.emplace(handle, std::move(value)); return handle;
    } catch (const std::exception& failure) { if (error && capacity) snprintf(error, capacity, "%s", failure.what()); return 0; }
}
extern "C" void airplay_receiver_destroy(uint64_t handle) {
    std::shared_ptr<Receiver> value;
    { std::lock_guard<std::mutex> guard(registry_lock); auto found = receivers.find(handle);
      if (found == receivers.end()) return; value = std::move(found->second); receivers.erase(found); }
    value->close();
}
extern "C" void airplay_receiver_free_snapshot(AirplayReceiverSnapshot* value) {
    if (!value) return;
    for (auto settings : {&value->settings, &value->active_settings}) { free(const_cast<char*>(settings->name)); free(const_cast<char*>(settings->path)); }
    for (auto bytes : {value->message, value->client_name, value->receiving_name, value->default_name, value->build_time, value->platform}) free(const_cast<char*>(bytes));
    if (value->logs) for (size_t i = 0; i < value->log_count; ++i) { free(const_cast<char*>(value->logs[i].time)); free(const_cast<char*>(value->logs[i].text)); }
    free(const_cast<AirplayReceiverLog*>(value->logs)); delete value;
}
extern "C" AirplayReceiverSnapshot* airplay_receiver_snapshot(uint64_t handle, char* error, size_t capacity) {
    AirplayReceiverSnapshot* result = nullptr; native_action(handle, error, capacity, [&](Receiver& value) { result = value.read_snapshot(); }); return result;
}
extern "C" bool airplay_receiver_save(uint64_t handle, const AirplayReceiverSettings* settings, char* error, size_t capacity) {
    return native_action(handle, error, capacity, [&](Receiver& value) { if (!settings) throw std::runtime_error("Missing receiver settings"); auto arguments = copied_settings(*settings); value.configure(arguments); });
}
extern "C" bool airplay_receiver_start(uint64_t handle, uint64_t expected_generation, char* error, size_t capacity) {
    return native_action(handle, error, capacity, [expected_generation](Receiver& value) { value.begin(expected_generation); });
}
extern "C" bool airplay_receiver_stop(uint64_t handle, char* error, size_t capacity) {
    return native_action(handle, error, capacity, [](Receiver& value) { value.end(); });
}
extern "C" bool airplay_receiver_disconnect(uint64_t handle, char* error, size_t capacity) {
    return native_action(handle, error, capacity, [](Receiver& value) { value.disconnect(); });
}
extern "C" bool airplay_receiver_suspend(uint64_t handle, char* error, size_t capacity) {
    return native_action(handle, error, capacity, [](Receiver& value) { value.suspend(); });
}
extern "C" bool airplay_receiver_resume(uint64_t handle, char* error, size_t capacity) {
    return native_action(handle, error, capacity, [](Receiver& value) { value.resume(); });
}
extern "C" bool airplay_receiver_apply_settings(uint64_t handle, bool* applied, char* error, size_t capacity) {
    return native_action(handle, error, capacity, [&](Receiver& value) { if (!applied) throw std::runtime_error("Missing apply result"); *applied = value.apply_settings(); });
}
extern "C" bool airplay_receiver_check(uint64_t handle, const char* path, size_t size, char* error, size_t capacity) {
    return native_action(handle, error, capacity, [&](Receiver& value) { value.check(copied_text(path, size)); });
}
extern "C" bool airplay_receiver_requested_video_size(uint64_t handle, AirplayVideoSize* size, char* error, size_t capacity) {
    return native_action(handle, error, capacity, [&](Receiver& value) { if (!size) throw std::runtime_error("Missing video size"); *size = value.requested_video_size(); });
}
extern "C" void airplay_receiver_request_start(uint64_t handle) {
    try { if (auto value = receiver(handle)) value->enqueue([value] { value->request_start(); }); } catch (...) {}
}
extern "C" void airplay_receiver_request_stop(uint64_t handle) {
    try { if (auto value = receiver(handle)) value->enqueue([value] { value->end(); }); } catch (...) {}
}
extern "C" void airplay_receiver_request_settings(uint64_t handle, const AirplayReceiverSettings* settings) {
    try { if (auto value = receiver(handle); value && settings) {
        auto arguments = std::make_shared<Settings>(copied_settings(*settings));
        value->enqueue([value, arguments] { value->request_settings(*arguments); });
    } } catch (...) {}
}
extern "C" void airplay_receiver_discovery(uint64_t handle, uint64_t generation, bool ready, const char *error, const char *name) {
    if (auto value = receiver(handle)) value->discovery(generation, ready, error ? error : "", name ? name : "");
}
extern "C" bool airplay_receiver_set_surface(uint64_t handle, void *surface) {
    try { auto value = receiver(handle); return value && value->surface(surface); } catch (...) { return false; }
}
extern "C" void airplay_receiver_update(uint64_t handle, const char *json) { if (auto value = receiver(handle); value && json) value->update(json); }
extern "C" void airplay_receiver_log(uint64_t handle, const char *message) {
    if (auto value = receiver(handle); value && message) { std::string bytes(message); value->enqueue([value, bytes] { value->log(bytes); }); }
}
extern "C" void airplay_receiver_output_error(uint64_t handle, const char *message) {
    if (auto value = receiver(handle); value && message) value->output_error(message);
}

namespace airplay {
bool observe_receiver(uint64_t handle, std::shared_ptr<ReceiverObserver> observer) {
    auto value = receiver(handle); return value && value->observe(std::move(observer));
}
bool enqueue_receiver(uint64_t handle, std::function<void()> task) {
    auto value = receiver(handle); return value && value->enqueue(std::move(task));
}
}  // namespace airplay

namespace airplay {
Json control_receiver(uint64_t handle, const std::string& request) {
    auto value = receiver(handle);
    if (!value) throw std::runtime_error("Receiver has closed");
    auto message = parse_json(request.c_str());
    return value->sync([&] { return value->control(message.get()); });
}
}  // namespace airplay
