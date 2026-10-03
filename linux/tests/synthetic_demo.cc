// SPDX-License-Identifier: GPL-3.0-only
// Developer-only visual fixture. Loads the existing root Flutter app bundle and
// replaces its receiver channels with an explicitly synthetic test adapter.
// No receiver, Avahi client, network listener or audio output is started.
// Usage: linux_synthetic_demo /absolute/path/to/flutter/bundle [portrait]
#include "linux/runner/frame_texture.h"
#include "linux/runner/window_channel.h"
#include "native/player/platform.h"
#include "native/player-tests/video_fixtures.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstdio>
#include <memory>
#include <string>

namespace {
void String(FlValue* map, const char* key, const char* value) {
  fl_value_set_string_take(map, key, fl_value_new_string(value));
}
void Integer(FlValue* map, const char* key, int64_t value) {
  fl_value_set_string_take(map, key, fl_value_new_int(value));
}
void Boolean(FlValue* map, const char* key, bool value) {
  fl_value_set_string_take(map, key, fl_value_new_bool(value));
}

class SyntheticDemo {
 public:
  SyntheticDemo(FlEngine* engine, bool portrait)
      : messenger_(FL_BINARY_MESSENGER(g_object_ref(fl_engine_get_binary_messenger(engine)))),
        texture_(std::make_unique<FrameTexture>(fl_engine_get_texture_registrar(engine))),
        portrait_(portrait) {
    decoder_ = airplay::make_video_output(nullptr, nullptr, nullptr, {
      [this](void* borrowed, int width, int height, int64_t, uint64_t) {
        if (!texture_->Receive(*static_cast<AirplayLinuxVideoFrame*>(borrowed))) return;
        width_ = width;
        height_ = height;
        texture_->Notify();
        std::fprintf(stdout, "Synthetic decoded texture: %dx%d, texture %lld\n", width_, height_,
                     static_cast<long long>(texture_->identifier()));
        std::fflush(stdout);
      }, [](const char* text) { std::fprintf(stderr, "Synthetic decoder: %s\n", text); }
    });
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    methods_ = fl_method_channel_new(messenger_, "org.airplayreceiver/control", FL_METHOD_CODEC(codec));
    events_ = fl_event_channel_new(messenger_, "org.airplayreceiver/events", FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(methods_,
        [](FlMethodChannel*, FlMethodCall* call, gpointer self) {
          static_cast<SyntheticDemo*>(self)->Method(call);
        }, this, nullptr);
    fl_event_channel_set_stream_handlers(events_,
        [](FlEventChannel*, FlValue*, gpointer data) -> FlMethodErrorResponse* {
          auto* self = static_cast<SyntheticDemo*>(data);
          self->listening_ = true;
          // Defer the first event until the listen response has reached Dart.
          if (!self->snapshot_source_) self->snapshot_source_ = g_idle_add([](gpointer data) -> gboolean {
            auto* demo = static_cast<SyntheticDemo*>(data);
            demo->snapshot_source_ = 0;
            demo->Publish();
            return G_SOURCE_REMOVE;
          }, self);
          return nullptr;
        }, [](FlEventChannel*, FlValue*, gpointer data) -> FlMethodErrorResponse* {
          static_cast<SyntheticDemo*>(data)->listening_ = false;
          return nullptr;
        }, this, nullptr);
  }

  ~SyntheticDemo() {
    if (snapshot_source_) g_source_remove(snapshot_source_);
    fl_method_channel_set_method_call_handler(methods_, nullptr, nullptr, nullptr);
    fl_event_channel_set_stream_handlers(events_, nullptr, nullptr, nullptr, nullptr);
    fl_binary_messenger_set_message_handler_on_channel(messenger_, "org.airplayreceiver/control",
                                                        nullptr, nullptr, nullptr);
    fl_binary_messenger_set_message_handler_on_channel(messenger_, "org.airplayreceiver/events",
                                                        nullptr, nullptr, nullptr);
    decoder_.reset();
    texture_.reset();
    g_object_unref(methods_);
    g_object_unref(events_);
    g_object_unref(messenger_);
  }

 private:
  bool Decode() {
    if (!texture_->Register()) return false;
    decoder_->reset();
    const uint8_t* begin = portrait_ ? ::portrait : landscape;
    const size_t size = portrait_ ? sizeof(::portrait) : sizeof(landscape);
    const int w = portrait_ ? landscape_height : landscape_width;
    const int h = portrait_ ? landscape_width : landscape_height;
    decoder_->size(w, h);
    if (!decoder_->decode({std::vector<uint8_t>(begin, begin + size), airplay::monotonic_ns(), 1}))
      return false;
    decoder_->drain();
    return width_ > 0 && height_ > 0;
  }

  FlValue* Snapshot() {
    auto* data = fl_value_new_map();
    String(data, "status", running_ ? "streaming" : "stopped");
    String(data, "message", "SYNTHETIC H.264 FIXTURE - no receiver or network");
    String(data, "name", "Synthetic H.264 fixture");
    String(data, "path", "");
    String(data, "clientName", "Synthetic fixture (no iPhone)");
    Integer(data, "pid", 0);
    Integer(data, "textureId", texture_->identifier());
    Integer(data, "videoWidth", running_ ? width_ : 0);
    Integer(data, "videoHeight", running_ ? height_ : 0);
    Boolean(data, "autoStart", false);
    Boolean(data, "audioPlaying", false);
    Boolean(data, "videoPaused", false);
    auto* capabilities = fl_value_new_map();
    String(capabilities, "platform", "linux");
    Boolean(capabilities, "supportsExecutablePath", false);
    Boolean(capabilities, "supportsLaunchAtLogin", false);
    fl_value_set_string_take(data, "capabilities", capabilities);
    auto* logs = fl_value_new_list();
    auto* entry = fl_value_new_map();
    Integer(entry, "id", 1);
    g_autoptr(GDateTime) now = g_date_time_new_now_utc();
    g_autofree gchar* time = g_date_time_format_iso8601(now);
    String(entry, "time", time);
    String(entry, "text", "SYNTHETIC ONLY: H.264 fixture -> Linux decoder -> RGBA texture -> shared root Flutter UI. "
                          "No receiver, mDNS, sender or audio device is running.");
    fl_value_append_take(logs, entry);
    fl_value_set_string_take(data, "logs", logs);
    return data;
  }

  void Publish() {
    if (!listening_) return;
    g_autoptr(FlValue) event = fl_value_new_map();
    String(event, "type", "snapshot");
    fl_value_set_string_take(event, "data", Snapshot());
    fl_event_channel_send(events_, event, nullptr, nullptr);
  }

  void Method(FlMethodCall* call) {
    const std::string method = fl_method_call_get_name(call);
    if (method == "snapshot") {
      if (!initialized_) {
        initialized_ = true;
        running_ = Decode();
        if (!running_) {
          fl_method_call_respond_error(call, "fixture_error", "Synthetic H.264 decode failed", nullptr, nullptr);
          return;
        }
      }
      g_autoptr(FlValue) data = Snapshot();
      fl_method_call_respond_success(call, data, nullptr);
    } else if (method == "start") {
      running_ = Decode();
      if (!running_) fl_method_call_respond_error(call, "fixture_error", "Synthetic H.264 decode failed", nullptr, nullptr);
      else fl_method_call_respond_success(call, nullptr, nullptr);
      Publish();
    } else if (method == "stop") {
      running_ = false;
      decoder_->reset();
      texture_->Clear();
      texture_->Notify();
      fl_method_call_respond_success(call, nullptr, nullptr);
      Publish();
    } else if (method == "save" || method == "check") {
      fl_method_call_respond_error(call, "fixture_only", "This is a read-only synthetic visual fixture", nullptr, nullptr);
    } else {
      fl_method_call_respond_not_implemented(call, nullptr);
    }
  }

  FlBinaryMessenger* messenger_;
  std::unique_ptr<FrameTexture> texture_;
  std::unique_ptr<airplay::VideoOutput> decoder_;
  FlMethodChannel* methods_ = nullptr;
  FlEventChannel* events_ = nullptr;
  bool portrait_;
  bool running_ = false;
  bool initialized_ = false;
  bool listening_ = false;
  int width_ = 0;
  int height_ = 0;
  guint snapshot_source_ = 0;
};
}  // namespace

int main(int argc, char** argv) {
  if (argc < 2 || argc > 3 || !g_path_is_absolute(argv[1])) {
    std::fprintf(stderr, "Usage: %s /absolute/path/to/flutter/bundle [portrait]\n", argv[0]);
    return 2;
  }
  const bool portrait = argc == 3 && g_strcmp0(argv[2], "portrait") == 0;
  const std::string bundle = argv[1];
  gtk_init(nullptr, nullptr);
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  g_autofree gchar* assets = g_build_filename(bundle.c_str(), "data", "flutter_assets", nullptr);
  g_autofree gchar* icu = g_build_filename(bundle.c_str(), "data", "icudtl.dat", nullptr);
  g_autofree gchar* aot = g_build_filename(bundle.c_str(), "lib", "libapp.so", nullptr);
  fl_dart_project_set_assets_path(project, assets);
  fl_dart_project_set_icu_data_path(project, icu);
  if (g_file_test(aot, G_FILE_TEST_IS_REGULAR)) fl_dart_project_set_aot_library_path(project, aot);
  auto* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), portrait
      ? "SYNTHETIC ONLY - Linux decoded portrait - no receiver/network"
      : "SYNTHETIC ONLY - Linux decoded landscape - no receiver/network");
  gtk_window_set_default_size(GTK_WINDOW(window), 980, 680);
  auto* view = fl_view_new(project);
  auto window_channel = std::make_unique<WindowChannel>(fl_engine_get_binary_messenger(fl_view_get_engine(view)), GTK_WINDOW(window));
  auto demo = std::make_unique<SyntheticDemo>(fl_view_get_engine(view), portrait);
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  g_signal_connect(window, "delete-event", G_CALLBACK(+[](GtkWidget*, GdkEvent*, gpointer data) -> gboolean {
    static_cast<std::unique_ptr<SyntheticDemo>*>(data)->reset();
    return FALSE;
  }), &demo);
  g_signal_connect(window, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer) { gtk_main_quit(); }), nullptr);
  gtk_widget_show_all(window);
  gtk_widget_grab_focus(GTK_WIDGET(view));
  gtk_main();
  demo.reset();
  window_channel.reset();
  return 0;
}
