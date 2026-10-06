// SPDX-License-Identifier: GPL-3.0-only
#include "receiver_host.h"
#include "build_info.h"

#include "discovery.h"
#include "frame_texture.h"
#include "../../native/include/airplay/receiver.h"
#include <gdk/gdk.h>

#include <glib/gstdio.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
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
std::string TextArgument(FlValue* args, const char* key) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return "";
  auto* value = fl_value_lookup_string(args, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value) : "";
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
  GMainContext* main_context = g_main_context_ref_thread_default();
  FlMethodChannel* methods = nullptr;
  FlBinaryMessenger* messenger = nullptr;
  std::unique_ptr<FrameTexture> texture;
  std::atomic<int64_t> texture_id{-1};
  std::atomic<bool> closing{false}, frame_notification{false};
  std::function<void(FlValue*)> on_snapshot;
  uint64_t handle = 0;
  Discovery discovery;
  AirplayCallbacks video_callbacks{};
  GKeyFile* preferences = g_key_file_new();
  std::string config_directory, preferences_path, key_path, config_error;
  int screen_width = 1920, screen_height = 1080;
  std::array<uint8_t, 6> identity{};
  ~State() { g_key_file_unref(preferences); g_main_context_unref(main_context); }
  static std::string Encode(FlValue* value) {
    g_autoptr(FlJsonMessageCodec) codec = fl_json_message_codec_new();
    g_autoptr(GError) error = nullptr;
    g_autoptr(GBytes) bytes = fl_message_codec_encode_message(FL_MESSAGE_CODEC(codec), value, &error);
    if (!bytes) throw Failure("Cannot encode native metadata: ", error);
    gsize size = 0; const auto* data = static_cast<const char*>(g_bytes_get_data(bytes, &size));
    return std::string(data, size);
  }
  static Value Decode(const char* json) {
    g_autoptr(FlJsonMessageCodec) codec = fl_json_message_codec_new();
    g_autoptr(GBytes) bytes = g_bytes_new(json, strlen(json));
    return Own(fl_message_codec_decode_message(FL_MESSAGE_CODEC(codec), bytes, nullptr));
  }
  Value Metadata() {
    auto value = Own(fl_value_new_map());
    String(value.get(), "defaultName", DefaultName()); String(value.get(), "buildTime", AIRPLAY_BUILD_TIME);
    Integer(value.get(), "screenWidth", screen_width); Integer(value.get(), "screenHeight", screen_height);
    auto* caps = fl_value_new_map(); String(caps, "platform", "linux");
    Boolean(caps, "supportsExecutablePath", false); Boolean(caps, "supportsLaunchAtLogin", true);
    fl_value_set_string_take(value.get(), "capabilities", caps); return value;
  }
  void Create() {
    Load();
    AirplayReceiverHost hooks{}; hooks.context = this;
    hooks.create_player = [](void* context, AirplayCallbacks callbacks, int, int, int, char* error, size_t capacity) {
      auto* self = static_cast<State*>(context);
      if (self->texture_id < 0) { snprintf(error, capacity, "Flutter video texture is unavailable"); return static_cast<AirplayPlayer*>(nullptr); }
      std::string detail;
      if (!Discovery::Check(&detail)) { snprintf(error, capacity, "%s", detail.c_str()); return static_cast<AirplayPlayer*>(nullptr); }
      self->video_callbacks = callbacks;
      AirplayLinuxVideoOptions options{};
      return airplay_player_create(callbacks, &options, nullptr, nullptr);
    };
    hooks.texture_id = [](void* context) { return static_cast<State*>(context)->texture_id.load(); };
    hooks.end_video = [](void* context, bool) { static_cast<State*>(context)->ClearFrame(); };
    hooks.clear_video = [](void* context) { static_cast<State*>(context)->ClearFrame(); };
    hooks.frame = [](void* context, void* frame) {
      auto* self = static_cast<State*>(context);
      if (frame && !self->closing) {
        const auto error = self->texture->TakeError();
        if (!error.empty()) {
          if (self->video_callbacks.log) self->video_callbacks.log(self->video_callbacks.context, 3, error.c_str());
          if (self->video_callbacks.event) self->video_callbacks.event(self->video_callbacks.context, "error", error.c_str(), 0, 0);
          return;
        }
      }
      if (frame && !self->closing && self->texture->Receive(*static_cast<AirplayLinuxVideoFrame*>(frame))) self->NotifyFrame();
    };
    hooks.publish = [](void* context, uint64_t epoch, const char* name, const uint8_t* identity, uint16_t port,
                       const uint8_t* video, size_t video_size, const uint8_t* audio, size_t audio_size,
                       char* error, size_t capacity) {
      auto* self = static_cast<State*>(context); std::array<uint8_t, 6> id{}; std::copy_n(identity, 6, id.begin());
      std::weak_ptr<State> weak = self->shared_from_this(); std::string detail;
      const bool ready = self->discovery.Start(name, id, port, std::vector<uint8_t>(video, video + video_size),
          std::vector<uint8_t>(audio, audio + audio_size), [weak, epoch](const std::string& failure) {
            if (auto current = weak.lock()) airplay_receiver_discovery(current->handle, epoch, false, failure.c_str(), nullptr);
          }, &detail);
      if (!ready) snprintf(error, capacity, "%s", detail.c_str()); return ready ? 1 : -1;
    };
    hooks.unpublish = [](void* context) { static_cast<State*>(context)->discovery.Stop(); };
    hooks.check = [](void*, char* error, size_t capacity) {
      std::string detail; const bool ready = Discovery::Check(&detail);
      if (!ready) snprintf(error, capacity, "%s", detail.c_str()); return ready;
    };
    hooks.diagnostics = [](void* context, char* output, size_t capacity) {
      const auto report = static_cast<State*>(context)->texture->Diagnostics();
      if (!report.empty()) snprintf(output, capacity, "%s", report.c_str());
    };
    hooks.event = [](void* context, const char* json) {
      auto* self = static_cast<State*>(context); auto event = Decode(json);
      if (!event || TextArgument(event.get(), "type") != "snapshot") return;
      auto* data = fl_value_lookup_string(event.get(), "data"); if (!data) return;
      auto snapshot = Own(fl_value_ref(data)); std::weak_ptr<State> weak = self->shared_from_this();
      PostMain(self->main_context, [weak, snapshot] {
        if (auto current = weak.lock(); current && !current->closing && current->on_snapshot) current->on_snapshot(snapshot.get());
      });
    };
    char error[512]{};
    handle = airplay_receiver_create(hooks, Encode(Metadata().get()).c_str(), key_path.c_str(), identity.data(), error, sizeof(error));
    if (!handle) throw std::runtime_error(error);
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

  static std::string DefaultName() { return g_get_host_name(); }

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
    if (!saved_id) {
      char encoded[13];
      for (size_t i = 0; i < identity.size(); ++i)
        std::snprintf(encoded + 2 * i, 3, "%02X", identity[i]);
      g_key_file_set_string(preferences, "Receiver", "identity", encoded);
      WritePreferences();
    }
  }

  void NotifyFrame() {
    const bool coalesced = frame_notification.exchange(true);
    texture->NotificationRequested(coalesced);
    if (coalesced) return;
    std::weak_ptr<State> weak = shared_from_this();
    PostMain(main_context, [weak] {
      if (auto self = weak.lock()) {
        self->frame_notification = false;
        if (!self->closing) self->texture->Notify();
      }
    });
  }

  void ClearFrame() { texture->Clear(); NotifyFrame(); }

  // GDK is confined to the main thread; the host worker reads only pixel counts.
  void UpdateScreenSize() {
    auto* display = gdk_display_get_default();
    if (!display) return;
    auto* monitor = gdk_display_get_primary_monitor(display);
    if (!monitor && gdk_display_get_n_monitors(display) > 0)
      monitor = gdk_display_get_monitor(display, 0);
    if (!monitor) return;
    GdkRectangle geometry{};
    gdk_monitor_get_geometry(monitor, &geometry);
    const int scale = gdk_monitor_get_scale_factor(monitor);
    screen_width = geometry.width * scale;
    screen_height = geometry.height * scale;
  }

  void Handle(FlMethodCall* call) {
    if (strcmp(fl_method_call_get_name(call), "bootstrap")) { fl_method_call_respond_not_implemented(call, nullptr); return; }
    if (closing || !handle) { fl_method_call_respond_error(call, "receiver_error", config_error.c_str(), nullptr, nullptr); return; }
    texture->Register(); texture_id = texture->identifier(); UpdateScreenSize();
    airplay_receiver_update(handle, Encode(Metadata().get()).c_str());
    auto reply = Own(fl_value_new_map()); Integer(reply.get(), "handle", handle);
    fl_method_call_respond_success(call, reply.get(), nullptr);
  }
  void Install(FlBinaryMessenger* messenger, FlTextureRegistrar* registrar) {
    this->messenger = messenger;
    UpdateScreenSize(); texture = std::make_unique<FrameTexture>(registrar, true, true);
    try { Create(); } catch (const std::exception& error) { config_error = error.what(); }
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    methods = fl_method_channel_new(messenger, "org.airplayreceiver/platform", FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(methods, [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
      static_cast<State*>(data)->Handle(call);
    }, this, nullptr);
  }
  void Shutdown() {
    closing = true; on_snapshot = {};
    fl_method_channel_set_method_call_handler(methods, nullptr, nullptr, nullptr);
    // The messenger holds a channel reference until its handler is removed.
    fl_binary_messenger_set_message_handler_on_channel(messenger, "org.airplayreceiver/platform", nullptr, nullptr, nullptr);
    messenger = nullptr;
    airplay_receiver_destroy(handle); handle = 0; texture.reset(); g_clear_object(&methods);
  }
};

ReceiverHost::ReceiverHost(FlBinaryMessenger* messenger, FlTextureRegistrar* registrar,
                           std::function<void(FlValue*)> on_snapshot)
    : state_(std::make_shared<State>()) {
  state_->on_snapshot = std::move(on_snapshot);
  state_->Install(messenger, registrar);
}

ReceiverHost::~ReceiverHost() { state_->Shutdown(); }
