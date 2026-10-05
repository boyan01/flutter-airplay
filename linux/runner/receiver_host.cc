// SPDX-License-Identifier: GPL-3.0-only
#include "receiver_host.h"
#include "build_info.h"

#include "discovery.h"
#include "frame_texture.h"
#include "native/player/player.h"

#include <glib/gstdio.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <cerrno>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {
using Value = std::shared_ptr<FlValue>;
Value Own(FlValue* value) { return Value(value, fl_value_unref); }
void String(FlValue* map, const char* key, const std::string& value) {
  fl_value_set_string_take(map, key, fl_value_new_string(value.c_str()));
}
void Integer(FlValue* map, const char* key, int64_t value) {
  fl_value_set_string_take(map, key, fl_value_new_int(value));
}
void Boolean(FlValue* map, const char* key, bool value) {
  fl_value_set_string_take(map, key, fl_value_new_bool(value));
}
Value Event(const char* type) {
  auto value = Own(fl_value_new_map());
  String(value.get(), "type", type);
  return value;
}
std::string TextArgument(FlValue* args, const char* key) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return "";
  auto* value = fl_value_lookup_string(args, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value) : "";
}
std::string Trim(std::string value) {
  g_autofree gchar* text = g_strdup(value.c_str());
  return g_strstrip(text);
}
std::string SafeText(const char* text) {
  g_autofree gchar* valid = g_utf8_make_valid(text ? text : "", -1);
  std::string value(valid);
  if (value.size() > 4096) {
    value.resize(4096);
    while (!g_utf8_validate(value.c_str(), value.size(), nullptr)) value.pop_back();
  }
  return value;
}
bool ValidName(const std::string& name) {
  if (name.empty() || name.size() > 50 ||
      !g_utf8_validate(name.c_str(), name.size(), nullptr)) return false;
  for (const char* p = name.c_str(); *p; p = g_utf8_next_char(p))
    if (g_unichar_iscntrl(g_utf8_get_char(p))) return false;
  return true;
}
std::runtime_error Failure(const char* prefix, GError* error) {
  return std::runtime_error(std::string(prefix) + (error ? error->message : "Unknown error"));
}
void PostMain(GMainContext* context, std::function<void()> action) {
  // invoke_full may run inline on a worker if the context is not owned. An idle
  // source always defers to the GTK loop instead.
  auto* task = new std::function<void()>(std::move(action));
  GSource* source = g_idle_source_new();
  g_source_set_priority(source, G_PRIORITY_DEFAULT);
  g_source_set_callback(source, [](gpointer data) -> gboolean {
    (*static_cast<std::function<void()>*>(data))();
    return G_SOURCE_REMOVE;
  }, task, [](gpointer data) { delete static_cast<std::function<void()>*>(data); });
  g_source_attach(source, context);
  g_source_unref(source);
}
}  // namespace

struct ReceiverHost::State : std::enable_shared_from_this<ReceiverHost::State> {
  struct CallbackContext {
    std::weak_ptr<State> owner;
    uint64_t generation;
  };
  struct Log { int64_t id; std::string time; std::string text; };

  GMainContext* main_context = g_main_context_ref_thread_default();
  FlBinaryMessenger* binary_messenger = nullptr;
  FlMethodChannel* methods = nullptr;
  FlEventChannel* events = nullptr;
  std::unique_ptr<FrameTexture> texture;
  std::atomic<int64_t> texture_id{-1};
  std::atomic<bool> closing{false};
  std::atomic<bool> frame_notification{false};
  std::atomic<uint64_t> generation{0};
  std::atomic<uint64_t> listener_epoch{0};
  bool listening = false;  // Main thread only.
  std::function<void(FlValue*)> on_snapshot;  // Main thread only.
  std::map<FlMethodCall*, bool> pending_calls;  // Main thread only; owns refs.

  std::thread worker;
  std::mutex queue_mutex;
  std::condition_variable wake;
  std::deque<std::function<void()>> jobs;
  // Everything below belongs exclusively to the serial host worker.
  AirplayPlayer* player = nullptr;
  std::unique_ptr<CallbackContext> callback;
  Discovery discovery;
  GKeyFile* preferences = g_key_file_new();
  std::string config_directory;
  std::string preferences_path;
  std::string key_path;
  std::string config_error;
  std::string name = "Flutter AirPlay";
  std::string receiving_name;
  bool auto_start = true;
  const std::array<const char*, 4> window_keys{
      "keepInMenuBar", "showOnConnect", "fullscreenOnConnect", "alwaysOnTop"};
  std::array<bool, 4> window_options{true, true, false, false};
  std::array<uint8_t, 6> identity{};
  std::string status = "stopped";
  std::string message = "接收器未启动";
  std::string client_name;
  int width = 0;
  int height = 0;
  bool audio_playing = false;
  bool video_paused = false;
  int64_t log_id = 0;
  std::deque<Log> logs;

  ~State() {
    g_key_file_unref(preferences);
    g_main_context_unref(main_context);
  }

  void Queue(std::function<void()> job) {
    {
      std::lock_guard<std::mutex> lock(queue_mutex);
      if (closing) return;
      jobs.push_back(std::move(job));
    }
    wake.notify_one();
  }

  void Run() {
    try { Load(); }
    catch (const std::exception& error) { config_error = error.what(); }
    for (;;) {
      std::function<void()> job;
      {
        std::unique_lock<std::mutex> lock(queue_mutex);
        wake.wait(lock, [this] { return closing || !jobs.empty(); });
        if (closing) break;
        job = std::move(jobs.front());
        jobs.pop_front();
      }
      job();
    }
    ++generation;
    Cleanup();
  }

  void WritePreferences() {
    gsize size = 0;
    g_autofree gchar* bytes = g_key_file_to_data(preferences, &size, nullptr);
    g_autoptr(GError) error = nullptr;
    if (!g_file_set_contents_full(preferences_path.c_str(), bytes, size,
        static_cast<GFileSetContentsFlags>(G_FILE_SET_CONTENTS_CONSISTENT |
                                          G_FILE_SET_CONTENTS_DURABLE),
        0600, &error)) throw Failure("Cannot save receiver settings: ", error);
  }

  static std::string DefaultName() {
    const auto hostname = SafeText(g_get_host_name());
    std::string clean;
    for (const char* p = hostname.c_str(); *p; p = g_utf8_next_char(p)) {
      if (g_unichar_iscntrl(g_utf8_get_char(p))) continue;
      const size_t bytes = g_utf8_next_char(p) - p;
      if (clean.size() + bytes > 50) break;
      clean.append(p, bytes);
    }
    clean = Trim(clean);
    return ValidName(clean) ? clean : "Flutter AirPlay";
  }

  bool ApplySettings() {
    if (status != "waiting" || !player || !airplay_player_prepare_restart(player)) return false;
    auto args = Own(fl_value_new_map());
    String(args.get(), "name", name);
    Stop();
    try { Start(args.get()); }
    catch (const std::exception& error) {
      if (status != "error") Fail(error.what());
      throw;
    }
    return true;
  }

  void Load() {
    const char* base = g_get_user_config_dir();
    if (!base || !g_path_is_absolute(base))
      throw std::runtime_error("The XDG configuration directory must be an absolute path.");
    g_autofree gchar* directory = g_build_filename(base, "flutter-airplay", nullptr);
    config_directory = directory;
    if (g_mkdir_with_parents(directory, 0700) != 0 || g_chmod(directory, 0700) != 0)
      throw std::runtime_error("Cannot create the private receiver configuration directory.");
    preferences_path = config_directory + "/receiver.ini";
    key_path = config_directory + "/airplay-pairing.pem";
    g_autoptr(GError) error = nullptr;
    if (!g_key_file_load_from_file(preferences, preferences_path.c_str(),
                                   G_KEY_FILE_NONE, &error) &&
        !g_error_matches(error, G_FILE_ERROR, G_FILE_ERROR_NOENT))
      throw Failure("Cannot read receiver settings: ", error);
    g_autofree gchar* saved_name = g_key_file_get_string(preferences, "Receiver", "name", nullptr);
    if (saved_name) {
      if (!ValidName(saved_name)) throw std::runtime_error("The saved receiver name is invalid.");
      name = saved_name;
    } else {
      name = DefaultName();
    }
    if (g_key_file_has_key(preferences, "Receiver", "autoStart", nullptr))
      auto_start = g_key_file_get_boolean(preferences, "Receiver", "autoStart", nullptr);
    for (size_t i = 0; i < window_keys.size(); ++i)
      if (g_key_file_has_key(preferences, "Receiver", window_keys[i], nullptr))
        window_options[i] = g_key_file_get_boolean(preferences, "Receiver", window_keys[i], nullptr);
    g_autofree gchar* saved_id = g_key_file_get_string(preferences, "Receiver", "identity", nullptr);
    if (saved_id) {
      if (std::strlen(saved_id) != 12)
        throw std::runtime_error("The saved receiver identity is invalid.");
      for (size_t i = 0; i < identity.size(); ++i) {
        const int hi = g_ascii_xdigit_value(saved_id[2 * i]);
        const int lo = g_ascii_xdigit_value(saved_id[2 * i + 1]);
        if (hi < 0 || lo < 0) throw std::runtime_error("The saved receiver identity is invalid.");
        identity[i] = static_cast<uint8_t>((hi << 4) | lo);
      }
      if ((identity[0] & 3) != 2)
        throw std::runtime_error("The saved receiver identity must be locally administered and unicast.");
    } else {
      size_t offset = 0;
      while (offset < identity.size()) {
        const ssize_t count = getrandom(identity.data() + offset, identity.size() - offset, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) throw std::runtime_error("Cannot generate a private receiver identity.");
        offset += static_cast<size_t>(count);
      }
      identity[0] = (identity[0] | 2) & 254;
    }
    char encoded[13];
    for (size_t i = 0; i < identity.size(); ++i)
      std::snprintf(encoded + 2 * i, 3, "%02X", identity[i]);
    g_key_file_set_string(preferences, "Receiver", "identity", encoded);
    g_key_file_set_string(preferences, "Receiver", "name", name.c_str());
    g_key_file_set_boolean(preferences, "Receiver", "autoStart", auto_start);
    WritePreferences();
  }

  Value LogValue(const Log& log) {
    auto item = Own(fl_value_new_map());
    Integer(item.get(), "id", log.id);
    String(item.get(), "time", log.time);
    String(item.get(), "text", log.text);
    return item;
  }

  Value Snapshot() {
    auto data = Own(fl_value_new_map());
    String(data.get(), "status", status);
    String(data.get(), "buildTime", AIRPLAY_BUILD_TIME);
    String(data.get(), "message", message);
    String(data.get(), "name", name);
    String(data.get(), "receivingName", receiving_name);
    String(data.get(), "defaultName", DefaultName());
    auto active_settings = Own(fl_value_new_map());
    String(active_settings.get(), "name", receiving_name);
    String(active_settings.get(), "path", "");
    fl_value_set_string(data.get(), "activeSettings", active_settings.get());
    String(data.get(), "path", "");
    String(data.get(), "clientName", client_name);
    Integer(data.get(), "pid", player ? getpid() : 0);
    Integer(data.get(), "textureId", texture_id);
    Integer(data.get(), "videoWidth", width);
    Integer(data.get(), "videoHeight", height);
    Boolean(data.get(), "autoStart", auto_start);
    Boolean(data.get(), "audioPlaying", audio_playing);
    Boolean(data.get(), "videoPaused", video_paused);
    Boolean(data.get(), "launchAtLogin", false);
    for (size_t i = 0; i < window_keys.size(); ++i)
      Boolean(data.get(), window_keys[i], window_options[i]);
    auto* capabilities = fl_value_new_map();
    String(capabilities, "platform", "linux");
    Boolean(capabilities, "supportsExecutablePath", false);
    Boolean(capabilities, "supportsLaunchAtLogin", false);
    fl_value_set_string_take(data.get(), "capabilities", capabilities);
    auto* entries = fl_value_new_list();
    for (const auto& item : logs) fl_value_append(entries, LogValue(item).get());
    fl_value_set_string_take(data.get(), "logs", entries);
    return data;
  }

  void Emit(Value event) {
    auto snapshot = TextArgument(event.get(), "type") != "log" ? Snapshot() : Value{};
    const auto token = generation.load();
    const auto epoch = listener_epoch.load();
    std::weak_ptr<State> weak = shared_from_this();
    PostMain(main_context, [weak, token, epoch, event = std::move(event), snapshot = std::move(snapshot)] {
      if (auto self = weak.lock()) {
        if (self->closing || token != self->generation) return;
        if (snapshot && self->on_snapshot) self->on_snapshot(snapshot.get());
        if (!self->listening || epoch != self->listener_epoch) return;
        g_autoptr(GError) error = nullptr;
        if (!fl_event_channel_send(self->events, event.get(), nullptr, &error))
          g_warning("Receiver event could not be delivered: %s",
                    error ? error->message : "Flutter engine unavailable");
      }
    });
  }

  void EmitSnapshot() {
    auto event = Event("snapshot");
    fl_value_set_string(event.get(), "data", Snapshot().get());
    Emit(std::move(event));
  }

  void LogText(const std::string& text) {
    g_autoptr(GDateTime) now = g_date_time_new_now_utc();
    g_autofree gchar* time = g_date_time_format_iso8601(now);
    logs.push_back({++log_id, time, SafeText(text.c_str())});
    if (logs.size() > 300) logs.pop_front();
    auto event = Event("log");
    fl_value_set_string(event.get(), "entry", LogValue(logs.back()).get());
    Emit(std::move(event));
  }

  void SetState(const std::string& next, const std::string& detail) {
    status = next;
    message = detail;
    if (next == "waiting" || next == "stopping" || next == "stopped" || next == "error") {
      client_name.clear();
      width = height = 0;
      audio_playing = video_paused = false;
    }
    auto event = Event("state");
    String(event.get(), "status", status);
    String(event.get(), "message", message);
    Integer(event.get(), "pid", player ? getpid() : 0);
    Emit(std::move(event));
  }

  void Media() {
    auto event = Event("media");
    Boolean(event.get(), "audioPlaying", audio_playing);
    Boolean(event.get(), "videoPaused", video_paused);
    Emit(std::move(event));
  }

  void Video() {
    auto event = Event("video");
    Integer(event.get(), "textureId", texture_id);
    Integer(event.get(), "videoWidth", width);
    Integer(event.get(), "videoHeight", height);
    Emit(std::move(event));
  }

  void NotifyFrame() {
    if (frame_notification.exchange(true)) return;
    std::weak_ptr<State> weak = shared_from_this();
    PostMain(main_context, [weak] {
      if (auto self = weak.lock()) {
        self->frame_notification = false;
        if (!self->closing) self->texture->Notify();
      }
    });
  }

  void ClearFrame() { texture->Clear(); NotifyFrame(); }

  void Receive(const std::string& event, const std::string& detail, int w, int h) {
    if (!player) return;
    if (event == "client") {
      client_name = detail;
      auto value = Event("client");
      String(value.get(), "name", detail);
      Emit(std::move(value));
      SetState("streaming", "已建立连接，等待第一帧画面");
    } else if (event == "connecting") {
      if (!width) SetState("streaming", "已建立连接，等待第一帧画面");
    } else if (event == "playing") {
      if (video_paused) { video_paused = false; Media(); }
      if (width != w || height != h) { width = w; height = h; Video(); }
      if (message != "正在播放屏幕镜像") SetState("streaming", "正在播放屏幕镜像");
    } else if (event == "waiting") {
      ClearFrame();
      SetState("waiting", "连接已结束 · 等待下一次投屏");
    } else if (event == "paused" || event == "reset") {
      video_paused = event == "paused";
      if (event == "reset") audio_playing = false;
      ClearFrame();
      width = height = 0;
      Video();
      Media();
      if (video_paused) SetState("streaming", "画面已暂停");
    } else if (event == "audio" || event == "audio_stopped") {
      audio_playing = event == "audio";
      Media();
      if (audio_playing && !width) SetState("streaming", "音频播放中");
    } else if (event == "error") {
      Fail(detail);
    }
  }

  void Save(FlValue* args) {
    if (!config_error.empty()) throw std::runtime_error(config_error);
    const auto next = Trim(TextArgument(args, "name"));
    if (!Trim(TextArgument(args, "path")).empty())
      throw std::runtime_error("Linux uses the built-in C++ receiver; no executable path is needed.");
    if (!ValidName(next))
      throw std::runtime_error("Device name must contain 1–50 UTF-8 bytes and no control characters.");
    auto* launch = fl_value_lookup_string(args, "launchAtLogin");
    if (launch && fl_value_get_type(launch) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(launch))
      throw std::runtime_error("Launch at login is not supported by this Linux host.");
    bool next_auto = auto_start;
    auto* automatic = fl_value_lookup_string(args, "autoStart");
    if (automatic && fl_value_get_type(automatic) == FL_VALUE_TYPE_BOOL)
      next_auto = fl_value_get_bool(automatic);
    auto next_options = window_options;
    for (size_t i = 0; i < window_keys.size(); ++i) {
      auto* option = fl_value_lookup_string(args, window_keys[i]);
      if (option && fl_value_get_type(option) == FL_VALUE_TYPE_BOOL)
        next_options[i] = fl_value_get_bool(option);
      g_key_file_set_boolean(preferences, "Receiver", window_keys[i], next_options[i]);
    }
    g_key_file_set_string(preferences, "Receiver", "name", next.c_str());
    g_key_file_set_boolean(preferences, "Receiver", "autoStart", next_auto);
    try { WritePreferences(); }
    catch (...) {
      g_key_file_set_string(preferences, "Receiver", "name", name.c_str());
      g_key_file_set_boolean(preferences, "Receiver", "autoStart", auto_start);
      for (size_t i = 0; i < window_keys.size(); ++i)
        g_key_file_set_boolean(preferences, "Receiver", window_keys[i], window_options[i]);
      throw;
    }
    name = next;
    auto_start = next_auto;
    window_options = next_options;
  }

  void Cleanup() {
    discovery.Stop();
    if (player) airplay_player_destroy(player);
    player = nullptr;
    callback.reset();
    ClearFrame();
  }

  void Fail(const std::string& detail) {
    ++generation;
    Cleanup();
    LogText(detail);
    SetState("error", detail);
  }

  void Stop() {
    ++generation;
    SetState("stopping", "正在停止接收器…");
    Cleanup();
    SetState("stopped", "接收器已停止");
  }

  void Start(FlValue* args) {
    if (player) return;
    Save(args);
    if (texture_id < 0) throw std::runtime_error("The Flutter video texture is not available.");
    const uint64_t token = ++generation;
    SetState("starting", "正在注册 Avahi 接收服务…");
    std::string availability_error;
    if (!Discovery::Check(&availability_error)) {
      Fail(availability_error);
      throw std::runtime_error(message);
    }
    callback = std::make_unique<CallbackContext>(CallbackContext{shared_from_this(), token});
    AirplayCallbacks callbacks{};
    callbacks.context = callback.get();
    callbacks.event = [](void* data, const char* type, const char* detail, int w, int h) {
      auto* context = static_cast<CallbackContext*>(data);
      if (auto self = context->owner.lock()) {
        const auto current = context->generation;
        const std::string event = SafeText(type), text = SafeText(detail);
        self->Queue([self_ptr = self.get(), current, event, text, w, h] {
          if (current == self_ptr->generation) self_ptr->Receive(event, text, w, h);
        });
      }
    };
    callbacks.log = [](void* data, int, const char* message) {
      auto* context = static_cast<CallbackContext*>(data);
      if (auto self = context->owner.lock()) {
        const auto current = context->generation;
        const auto text = SafeText(message);
        self->Queue([self_ptr = self.get(), current, text] {
          if (current == self_ptr->generation) self_ptr->LogText(text);
        });
      }
    };
    callbacks.frame = [](void* data, void* frame) {
      auto* context = static_cast<CallbackContext*>(data);
      if (!frame) return;
      if (auto self = context->owner.lock()) {
        if (self->closing || context->generation != self->generation) return;
        // The native frame is borrowed only for this call. Copy synchronously;
        // neither the frame pointer nor its pixels may enter a deferred closure.
        if (self->texture->Receive(*static_cast<AirplayLinuxVideoFrame*>(frame)))
          self->NotifyFrame();
      }
    };
    player = airplay_player_create(callbacks, nullptr, nullptr, nullptr);
    if (!player) {
      Fail("Cannot initialize the native playback library.");
      throw std::runtime_error(message);
    }
    char error[512] = {};
    receiving_name = name;
    if (!airplay_player_start(player, name.c_str(), identity.data(), key_path.c_str(),
                               error, sizeof(error))) {
      Fail(SafeText(error));
      throw std::runtime_error(message);
    }
    if (g_chmod(key_path.c_str(), 0600) != 0) {
      Fail("Cannot secure the private AirPlay pairing key.");
      throw std::runtime_error(message);
    }
    std::vector<uint8_t> video(airplay_player_txt(player, false, nullptr, 0));
    std::vector<uint8_t> audio(airplay_player_txt(player, true, nullptr, 0));
    if (video.empty() || audio.empty() || video.size() > 65535 || audio.size() > 65535 ||
        airplay_player_txt(player, false, video.data(), video.size()) != video.size() ||
        airplay_player_txt(player, true, audio.data(), audio.size()) != audio.size()) {
      Fail("The native receiver returned invalid discovery records.");
      throw std::runtime_error(message);
    }
    std::weak_ptr<State> weak = shared_from_this();
    std::string discovery_error;
    if (!discovery.Start(name, identity, airplay_player_port(player), std::move(video),
                          std::move(audio), [weak, token](const std::string& detail) {
        if (auto self = weak.lock()) self->Queue([ptr = self.get(), token, detail] {
          if (token == ptr->generation) ptr->Fail(detail);
        });
      }, &discovery_error)) {
      Fail(discovery_error);
      throw std::runtime_error(message);
    }
    SetState("waiting", "等待 iPhone · 请在控制中心选择此设备");
  }

  void Reply(FlMethodCall* call, Value result, std::string error) {
    std::weak_ptr<State> weak = shared_from_this();
    PostMain(main_context, [weak, call, result = std::move(result), error = std::move(error)] {
      if (auto self = weak.lock()) {
        auto pending = self->pending_calls.find(call);
        if (pending == self->pending_calls.end()) return;
        if (error.empty()) fl_method_call_respond_success(call, result.get(), nullptr);
        else fl_method_call_respond_error(call, "receiver_error", error.c_str(), nullptr, nullptr);
        self->pending_calls.erase(pending);
        g_object_unref(call);
      }
    });
  }

  void Handle(FlMethodCall* call) {
    const std::string method = fl_method_call_get_name(call);
    if (method != "snapshot" && method != "save" && method != "start" &&
        method != "stop" && method != "check" && method != "applySettings") {
      fl_method_call_respond_not_implemented(call, nullptr);
      return;
    }
    if (closing) {
      fl_method_call_respond_error(call, "cancelled", "Receiver is shutting down", nullptr, nullptr);
      return;
    }
    texture->Register();
    texture_id = texture->identifier();
    auto* raw_args = fl_method_call_get_args(call);
    Value args = raw_args && fl_value_get_type(raw_args) == FL_VALUE_TYPE_MAP
                     ? Own(fl_value_ref(raw_args)) : Own(fl_value_new_map());
    g_object_ref(call);
    pending_calls.emplace(call, true);
    Queue([this, call, args = std::move(args), method] {
      Value result;
      std::string error;
      try {
        if (method == "snapshot") result = Snapshot();
        else if (method == "applySettings") result = Own(fl_value_new_bool(ApplySettings()));
        else if (method == "save") { Save(args.get()); EmitSnapshot(); }
        else if (method == "start") Start(args.get());
        else if (method == "stop") Stop();
        else if (method == "check") {
          if (!Trim(TextArgument(args.get(), "path")).empty())
            throw std::runtime_error("Linux uses the built-in C++ receiver.");
          if (!config_error.empty()) throw std::runtime_error(config_error);
          std::string detail;
          if (!Discovery::Check(&detail)) throw std::runtime_error(detail);
          LogText("Built-in FFmpeg / PulseAudio player loaded; Avahi daemon is available.");
        }
      } catch (const std::exception& exception) {
        error = SafeText(exception.what());
        if (method == "start" && status != "error") Fail(error);
      }
      Reply(call, std::move(result), std::move(error));
    });
  }

  void Install(FlBinaryMessenger* messenger, FlTextureRegistrar* registrar) {
    binary_messenger = FL_BINARY_MESSENGER(g_object_ref(messenger));
    texture = std::make_unique<FrameTexture>(registrar);
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    methods = fl_method_channel_new(messenger, "org.airplayreceiver/control", FL_METHOD_CODEC(codec));
    events = fl_event_channel_new(messenger, "org.airplayreceiver/events", FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(methods,
        [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
          static_cast<State*>(data)->Handle(call);
        }, this, nullptr);
    fl_event_channel_set_stream_handlers(events,
        [](FlEventChannel*, FlValue*, gpointer data) -> FlMethodErrorResponse* {
          auto* self = static_cast<State*>(data);
          self->texture->Register();
          self->texture_id = self->texture->identifier();
          self->listening = true;
          ++self->listener_epoch;
          self->Queue([self] { self->EmitSnapshot(); });
          return nullptr;
        }, [](FlEventChannel*, FlValue*, gpointer data) -> FlMethodErrorResponse* {
          auto* self = static_cast<State*>(data);
          self->listening = false;
          ++self->listener_epoch;
          return nullptr;
        }, this, nullptr);
    worker = std::thread([this] { Run(); });
  }

  void Shutdown() {
    on_snapshot = {};
    closing = true;
    listening = false;
    ++generation;
    fl_method_channel_set_method_call_handler(methods, nullptr, nullptr, nullptr);
    fl_event_channel_set_stream_handlers(events, nullptr, nullptr, nullptr, nullptr);
    for (auto& item : pending_calls) {
      fl_method_call_respond_error(item.first, "cancelled", "Receiver is shutting down", nullptr, nullptr);
      g_object_unref(item.first);
    }
    pending_calls.clear();
    fl_binary_messenger_set_message_handler_on_channel(binary_messenger,
        "org.airplayreceiver/control", nullptr, nullptr, nullptr);
    fl_binary_messenger_set_message_handler_on_channel(binary_messenger,
        "org.airplayreceiver/events", nullptr, nullptr, nullptr);
    {
      std::lock_guard<std::mutex> lock(queue_mutex);
      jobs.clear();
    }
    wake.notify_all();
    if (worker.joinable()) worker.join();
    texture.reset();
    g_clear_object(&methods);
    g_clear_object(&events);
    g_clear_object(&binary_messenger);
  }
};

ReceiverHost::ReceiverHost(FlBinaryMessenger* messenger, FlTextureRegistrar* registrar,
                           std::function<void(FlValue*)> on_snapshot)
    : state_(std::make_shared<State>()) {
  state_->on_snapshot = std::move(on_snapshot);
  state_->Install(messenger, registrar);
}

ReceiverHost::~ReceiverHost() { state_->Shutdown(); }
