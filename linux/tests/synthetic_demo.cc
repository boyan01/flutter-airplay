// SPDX-License-Identifier: GPL-3.0-only
// Developer-only visual fixture. Loads the existing root Flutter app bundle and
// replaces its receiver bootstrap and FFI commands with a synthetic adapter.
// No receiver, Avahi client, network listener or audio output is started.
// Usage: linux_synthetic_demo /absolute/path/to/flutter/bundle [portrait | --benchmark]
#include "linux/runner/frame_texture.h"
#include "linux/runner/window_channel.h"
#include "../../native/playback/platform.h"
#include "../../native/include/airplay/receiver_ffi.h"
#include <dart_native_api.h>
#include "../../native/tests/fixtures/video_fixtures.h"
#include "../../native/tests/fixtures/hevc_fixtures.h"
#include <atomic>
#include <thread>
#include <chrono>

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstdio>
#include <memory>
#include <mutex>
#include <map>
#include <functional>
#include <string>

namespace {
class SyntheticDemo;
SyntheticDemo* active_demo = nullptr;
int64_t dart_port = 0;
uint64_t subscription = 0;
bool (*post_object)(Dart_Port, Dart_CObject*) = nullptr;
std::mutex results_lock;
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
  SyntheticDemo(FlEngine* engine, bool portrait, bool benchmark = false)
      : messenger_(FL_BINARY_MESSENGER(g_object_ref(fl_engine_get_binary_messenger(engine)))),
        texture_(std::make_unique<FrameTexture>(fl_engine_get_texture_registrar(engine), benchmark, benchmark)),
        portrait_(portrait), benchmark_(benchmark) {
    AirplayLinuxVideoOptions options{};
    decoder_ = airplay::make_video_output(benchmark ? &options : nullptr, nullptr, nullptr, {
      [this](void* borrowed, int width, int height, int64_t, uint64_t) {
        if (!texture_->Receive(*static_cast<AirplayLinuxVideoFrame*>(borrowed))) return;
        if (benchmark_) { NotifyFrame(); return; }
        width_ = width;
        height_ = height;
        texture_->Notify();
        std::fprintf(stdout, "Synthetic decoded texture: %dx%d, texture %lld\n", width_, height_,
                     static_cast<long long>(texture_->identifier()));
        std::fflush(stdout);
      }, [](const char* text) { std::fprintf(stderr, "Synthetic decoder: %s\n", text); }
    });
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    methods_ = fl_method_channel_new(messenger_, "org.airplayreceiver/platform", FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(methods_, [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
      auto* self = static_cast<SyntheticDemo*>(data);
      if (strcmp(fl_method_call_get_name(call), "bootstrap")) { fl_method_call_respond_not_implemented(call, nullptr); return; }
      self->texture_->Register();
      g_autoptr(FlValue) reply = fl_value_new_map(); Integer(reply, "handle", 1);
      fl_method_call_respond_success(call, reply, nullptr);
    }, this, nullptr);
    { std::lock_guard<std::mutex> guard(results_lock); active_demo = this; }
  }

  ~SyntheticDemo() {
    alive_->store(false);
    stop_worker_ = true;
    if (worker_.joinable()) worker_.join();
    if (report_source_) g_source_remove(report_source_);
    { std::lock_guard<std::mutex> guard(results_lock); active_demo = nullptr; dart_port = 0; post_object = nullptr; ++subscription; }
    fl_method_channel_set_method_call_handler(methods_, nullptr, nullptr, nullptr);
    decoder_.reset();
    texture_.reset();
    g_object_unref(methods_);
    g_object_unref(messenger_);
  }

  static void Send(FlValue* message, uint64_t expected_subscription = 0) {
    std::lock_guard<std::mutex> guard(results_lock);
    if (expected_subscription && expected_subscription != subscription) return;
    if (!dart_port || !post_object) return;
    g_autoptr(FlJsonMessageCodec) codec = fl_json_message_codec_new();
    g_autoptr(GBytes) bytes = fl_message_codec_encode_message(FL_MESSAGE_CODEC(codec), message, nullptr);
    gsize length = 0; auto* data = static_cast<const char*>(g_bytes_get_data(bytes, &length));
    std::string json(data, length); Dart_CObject object{}; object.type = Dart_CObject_kString; object.value.as_string = json.c_str();
    post_object(dart_port, &object);
  }
  FlValue* ReadSnapshot() {
    if (!initialized_) { initialized_ = true; running_ = Decode(); }
    return Snapshot();
  }
  void Start() { running_ = Decode(); Publish(); }
  void Stop() { stop_worker_ = true; if (worker_.joinable()) worker_.join(); running_ = false; decoder_->reset(); texture_->Clear(); texture_->Notify(); Publish(); }

  bool BenchmarkPassed() const {
    return measured_received_ >= 870 && measured_acquired_ >= measured_received_ * .90 &&
        gpu_interop_ && gpu_errors_ == 0;
  }

 private:
  void NotifyFrame() {
    const bool coalesced = notification_pending_.exchange(true);
    texture_->NotificationRequested(coalesced);
    if (coalesced) return;
    struct Notification { SyntheticDemo* self; std::shared_ptr<std::atomic<bool>> alive; };
    auto* source = g_idle_source_new();
    g_source_set_priority(source, G_PRIORITY_DEFAULT);
    g_source_set_callback(source, [](gpointer value) -> gboolean {
      auto* item = static_cast<Notification*>(value);
      if (item->alive->load()) {
        item->self->notification_pending_ = false;
        item->self->texture_->Notify();
      }
      return G_SOURCE_REMOVE;
    }, new Notification{this, alive_}, [](gpointer value) { delete static_cast<Notification*>(value); });
    g_source_attach(source, nullptr); g_source_unref(source);
  }

  static uint64_t Count(const std::string& report, const char* field) {
    const auto at = report.find(std::string(field) + "=");
    return at == std::string::npos ? 0 : std::stoull(report.substr(at + strlen(field) + 1));
  }
  bool BeginBenchmark() {
    if (worker_.joinable()) return true;
    width_ = 3840; height_ = 2160;
    stop_worker_ = false;
    worker_ = std::thread([this] {
      const auto tick = airplay::kSecond / 60;
      const auto anchor = airplay::monotonic_ns() + 100000000;
      int input = 0;
      while (!stop_worker_) {
        const auto now = airplay::monotonic_ns();
        if (decoder_->can_decode() && anchor + input*tick <= now + 50000000) {
          if (!decoder_->decode({{hevc_fixtures::uhd, hevc_fixtures::uhd + sizeof(hevc_fixtures::uhd)},
              anchor + input*tick, 1, 0, true})) { stop_worker_ = true; break; }
          ++input;
        }
        decoder_->drain();
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    });
    report_source_ = g_timeout_add_seconds(5, [](gpointer data) -> gboolean {
      auto* self = static_cast<SyntheticDemo*>(data);
      const auto report = self->texture_->Diagnostics();
      std::printf("BENCHMARK %s\n", report.c_str()); std::fflush(stdout);
      if (self->reports_++ > 0) {
        self->gpu_interop_ = report.find("no CPU download") != std::string::npos;
        self->gpu_errors_ += Count(report, "gpu_errors");
        self->measured_ms_ += Count(report, "interval_ms");
        self->measured_received_ += Count(report, "received");
        self->measured_acquired_ += Count(report, "acquired_new");
      }
      if (self->reports_ == 4) {
        std::printf("BENCHMARK RESULT received=%llu acquired=%llu ratio=%.3f acquired_fps=%.2f threshold=0.90\n",
          static_cast<unsigned long long>(self->measured_received_),
          static_cast<unsigned long long>(self->measured_acquired_),
          self->measured_received_ ? double(self->measured_acquired_)/self->measured_received_ : 0,
          self->measured_ms_ ? 1000.0*self->measured_acquired_/self->measured_ms_ : 0);
        self->report_source_ = 0; gtk_main_quit(); return G_SOURCE_REMOVE;
      }
      return G_SOURCE_CONTINUE;
    }, this);
    return true;
  }
  bool Decode() {
    if (!texture_->Register()) return false;
    if (benchmark_) return BeginBenchmark();
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
    String(data, "message", benchmark_ ? "SYNTHETIC 4K60 GPU BENCHMARK - no receiver or network" : "SYNTHETIC H.264 FIXTURE - no receiver or network");
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
    String(entry, "text", benchmark_ ? "SYNTHETIC ONLY: HEVC 4K60 -> NVDEC -> GL texture -> real root Flutter UI; no network/audio." :
          "SYNTHETIC ONLY: H.264 fixture -> Linux decoder -> RGBA texture -> shared root Flutter UI. No network/audio.");
    fl_value_append_take(logs, entry);
    fl_value_set_string_take(data, "logs", logs);
    return data;
  }

  void Publish() {
    g_autoptr(FlValue) event = fl_value_new_map(); String(event, "type", "snapshot");
    fl_value_set_string_take(event, "data", Snapshot()); Send(event);
  }

  FlBinaryMessenger* messenger_;
  std::unique_ptr<FrameTexture> texture_;
  std::unique_ptr<airplay::VideoOutput> decoder_;
  FlMethodChannel* methods_ = nullptr;
  bool portrait_, benchmark_;
  std::shared_ptr<std::atomic<bool>> alive_ = std::make_shared<std::atomic<bool>>(true);
  std::atomic<bool> stop_worker_{false}, notification_pending_{false};
  std::thread worker_;
  guint report_source_ = 0;
  int reports_ = 0;
  uint64_t measured_received_ = 0, measured_acquired_ = 0, measured_ms_ = 0, gpu_errors_ = 0;
  bool gpu_interop_ = false;
  bool running_ = false;
  bool initialized_ = false;
  int width_ = 0;
  int height_ = 0;
};
}  // namespace

// Fixture-local JSON ABI exports take precedence over the shared library.
extern "C" uint32_t airplay_receiver_abi_version() { return 3; }
extern "C" uint64_t airplay_receiver_attach(uint64_t handle, int64_t port, void* callback) {
  std::lock_guard<std::mutex> guard(results_lock);
  if (handle != 1 || !active_demo) return 0;
  dart_port = port; post_object = reinterpret_cast<bool (*)(Dart_Port, Dart_CObject*)>(callback); return ++subscription;
}
extern "C" bool airplay_receiver_detach(uint64_t, uint64_t token) {
  std::lock_guard<std::mutex> guard(results_lock);
  if (token != subscription) return false;
  dart_port = 0; post_object = nullptr; ++subscription; return true;
}
extern "C" bool airplay_receiver_control(uint64_t handle, uint64_t token, int64_t id, const char* json, size_t size) {
  { std::lock_guard<std::mutex> guard(results_lock); if (handle != 1 || !active_demo || token != subscription) return false; }
  if (!json || size > 1024 * 1024) return false;
  struct Request { uint64_t token; int64_t id; std::string bytes; };
  auto* value = new Request{token, id, std::string(json, size)};
  g_idle_add_full(G_PRIORITY_DEFAULT, [](gpointer data) -> gboolean {
    auto* request = static_cast<Request*>(data);
    { std::lock_guard<std::mutex> guard(results_lock); if (!active_demo || request->token != subscription) return G_SOURCE_REMOVE; }
    g_autoptr(FlValue) completion = fl_value_new_map(); String(completion, "type", "complete"); Integer(completion, "request", request->id);
    g_autoptr(FlJsonMessageCodec) codec = fl_json_message_codec_new();
    g_autoptr(GBytes) bytes = g_bytes_new(request->bytes.data(), request->bytes.size());
    g_autoptr(FlValue) input = fl_message_codec_decode_message(FL_MESSAGE_CODEC(codec), bytes, nullptr);
    const char* method = nullptr;
    if (input && fl_value_get_type(input) == FL_VALUE_TYPE_MAP) {
      auto* field = fl_value_lookup_string(input, "method");
      if (field && fl_value_get_type(field) == FL_VALUE_TYPE_STRING) method = fl_value_get_string(field);
    }
    if (!method) String(completion, "error", "Invalid receiver command");
    else if (!strcmp(method, "snapshot")) fl_value_set_string_take(completion, "data", active_demo->ReadSnapshot());
    else {
      g_autoptr(FlValue) result = fl_value_new_map();
      if (!strcmp(method, "start") || !strcmp(method, "disconnect")) active_demo->Start();
      else if (!strcmp(method, "stop")) active_demo->Stop();
      else if (!strcmp(method, "applySettings")) Boolean(result, "applied", false);
      else if (strcmp(method, "save") && strcmp(method, "check")) String(completion, "error", "Unknown receiver command");
      fl_value_set_string_take(completion, "data", fl_value_ref(result));
    }
    SyntheticDemo::Send(completion, request->token); return G_SOURCE_REMOVE;
  }, value, [](gpointer data) { delete static_cast<Request*>(data); }); return true;
}

int main(int argc, char** argv) {
  if (argc < 2 || argc > 3 || !g_path_is_absolute(argv[1])) {
    std::fprintf(stderr, "Usage: %s /absolute/path/to/flutter/bundle [portrait | --benchmark]\n", argv[0]);
    return 2;
  }
  if (argc == 3 && strcmp(argv[2], "portrait") && strcmp(argv[2], "--benchmark")) return 2;
  const bool benchmark = argc == 3 && g_strcmp0(argv[2], "--benchmark") == 0;
  const bool portrait = argc == 3 && g_strcmp0(argv[2], "portrait") == 0;
  const std::string bundle = argv[1];
  // Keep the visual fixture's new settings key separate from product settings.
  g_autofree gchar* preferences_dir = g_dir_make_tmp("flutter-airplay-fixture-XXXXXX", nullptr);
  if (!preferences_dir) return 2;
  g_setenv("XDG_CONFIG_HOME", preferences_dir, TRUE);
  g_setenv("XDG_DATA_HOME", preferences_dir, TRUE);
  gtk_init(nullptr, nullptr);
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_ui_thread_policy(project, FL_UI_THREAD_POLICY_RUN_ON_PLATFORM_THREAD);
  g_autofree gchar* assets = g_build_filename(bundle.c_str(), "data", "flutter_assets", nullptr);
  g_autofree gchar* icu = g_build_filename(bundle.c_str(), "data", "icudtl.dat", nullptr);
  g_autofree gchar* aot = g_build_filename(bundle.c_str(), "lib", "libapp.so", nullptr);
  fl_dart_project_set_assets_path(project, assets);
  fl_dart_project_set_icu_data_path(project, icu);
  if (g_file_test(aot, G_FILE_TEST_IS_REGULAR)) fl_dart_project_set_aot_library_path(project, aot);
  auto* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), benchmark ? "SYNTHETIC ONLY - 4K60 pacing benchmark - no receiver/network" : portrait
      ? "SYNTHETIC ONLY - Linux decoded portrait - no receiver/network"
      : "SYNTHETIC ONLY - Linux decoded landscape - no receiver/network");
  gtk_window_set_default_size(GTK_WINDOW(window), 980, 680);
  gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
  auto* view = fl_view_new(project);
  auto window_channel = std::make_unique<WindowChannel>(fl_engine_get_binary_messenger(fl_view_get_engine(view)), GTK_WINDOW(window));
  auto demo = std::make_unique<SyntheticDemo>(fl_view_get_engine(view), portrait, benchmark);
  auto* overlay = gtk_overlay_new();
  gtk_container_add(GTK_CONTAINER(overlay), GTK_WIDGET(view));
  AddWindowResizeHandles(GTK_OVERLAY(overlay), GTK_WINDOW(window));
  gtk_container_add(GTK_CONTAINER(window), overlay);
  g_signal_connect(window, "delete-event", G_CALLBACK(+[](GtkWidget*, GdkEvent*, gpointer data) -> gboolean {
    static_cast<std::unique_ptr<SyntheticDemo>*>(data)->reset();
    return FALSE;
  }), &demo);
  g_signal_connect(window, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer) { if (gtk_main_level()) gtk_main_quit(); }), nullptr);
  gtk_widget_show_all(window);
  gtk_widget_grab_focus(GTK_WIDGET(view));
  gtk_main();
  const bool passed = !benchmark || (demo && demo->BenchmarkPassed());
  demo.reset();
  window_channel.reset();
  gtk_widget_destroy(window);
  return passed ? 0 : 1;
}
