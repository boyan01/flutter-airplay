// SPDX-License-Identifier: GPL-3.0-only
// Headless native-host regression. Uses real Flutter codecs, channels, GObjects
// and the texture copy_pixels callback with in-process messenger/registrar fakes.
// It does not establish GPU rendering, real mDNS publication or sender playback.
#include "linux/runner/discovery.h"
#include "linux/runner/frame_texture.h"
#include "linux/runner/receiver_host.h"

#include <glib/gstdio.h>
#include <sys/stat.h>

#include <chrono>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr char kControl[] = "org.airplayreceiver/control";
constexpr char kEvents[] = "org.airplayreceiver/events";
std::thread::id main_thread;
void OnMain() { g_assert_true(std::this_thread::get_id() == main_thread); }
void SpinUntil(const std::function<bool()>& done) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (!done()) {
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_assert_true(std::chrono::steady_clock::now() < deadline);
    g_usleep(1000);
  }
}
}  // namespace

typedef struct _TestRegistrar {
  GObject parent_instance;
  FlTexture* texture;
  unsigned marks;
} TestRegistrar;
typedef struct _TestRegistrarClass { GObjectClass parent_class; } TestRegistrarClass;
static void RegistrarInterface(FlTextureRegistrarInterface* iface);
G_DEFINE_TYPE_WITH_CODE(TestRegistrar, test_registrar, G_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(fl_texture_registrar_get_type(), RegistrarInterface))
static void test_registrar_class_init(TestRegistrarClass*) {}
static void test_registrar_init(TestRegistrar*) {}
static void RegistrarInterface(FlTextureRegistrarInterface* iface) {
  iface->register_texture = [](FlTextureRegistrar* object, FlTexture* texture) -> gboolean {
    OnMain();
    auto* self = reinterpret_cast<TestRegistrar*>(object);
    g_assert_null(self->texture);
    self->texture = FL_TEXTURE(g_object_ref(texture));
    FL_TEXTURE_GET_IFACE(texture)->set_id(texture, 42);
    return TRUE;
  };
  iface->unregister_texture = [](FlTextureRegistrar* object, FlTexture* texture) -> gboolean {
    OnMain();
    auto* self = reinterpret_cast<TestRegistrar*>(object);
    g_assert_true(self->texture == texture);
    g_clear_object(&self->texture);
    return TRUE;
  };
  iface->mark_texture_frame_available = [](FlTextureRegistrar* object, FlTexture*) -> gboolean {
    OnMain();
    ++reinterpret_cast<TestRegistrar*>(object)->marks;
    return TRUE;
  };
}

typedef struct _TestResponse {
  FlBinaryMessengerResponseHandle parent_instance;
  GBytes* bytes;
  bool done;
} TestResponse;
typedef struct _TestResponseClass {
  FlBinaryMessengerResponseHandleClass parent_class;
} TestResponseClass;
G_DEFINE_TYPE(TestResponse, test_response, fl_binary_messenger_response_handle_get_type())
static void test_response_class_init(TestResponseClass* klass) {
  G_OBJECT_CLASS(klass)->finalize = [](GObject* object) {
    auto* self = reinterpret_cast<TestResponse*>(object);
    g_clear_pointer(&self->bytes, g_bytes_unref);
    G_OBJECT_CLASS(test_response_parent_class)->finalize(object);
  };
}
static void test_response_init(TestResponse*) {}

struct Handler {
  FlBinaryMessengerMessageHandler callback;
  gpointer data;
  GDestroyNotify destroy;
};
typedef struct _TestMessenger {
  GObject parent_instance;
  std::map<std::string, Handler>* handlers;
  std::vector<FlValue*>* events;
} TestMessenger;
typedef struct _TestMessengerClass { GObjectClass parent_class; } TestMessengerClass;
static void MessengerInterface(FlBinaryMessengerInterface* iface);
G_DEFINE_TYPE_WITH_CODE(TestMessenger, test_messenger, G_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(fl_binary_messenger_get_type(), MessengerInterface))
static void test_messenger_init(TestMessenger* self) {
  self->handlers = new std::map<std::string, Handler>();
  self->events = new std::vector<FlValue*>();
}
static void test_messenger_class_init(TestMessengerClass* klass) {
  G_OBJECT_CLASS(klass)->finalize = [](GObject* object) {
    auto* self = reinterpret_cast<TestMessenger*>(object);
    g_assert_true(self->handlers->empty());
    delete self->handlers;
    for (auto* event : *self->events) fl_value_unref(event);
    delete self->events;
    G_OBJECT_CLASS(test_messenger_parent_class)->finalize(object);
  };
}
static void MessengerInterface(FlBinaryMessengerInterface* iface) {
  iface->set_message_handler_on_channel = [](
      FlBinaryMessenger* object, const gchar* channel,
      FlBinaryMessengerMessageHandler callback, gpointer data, GDestroyNotify destroy) {
    OnMain();
    auto* self = reinterpret_cast<TestMessenger*>(object);
    auto existing = self->handlers->find(channel);
    if (existing != self->handlers->end()) {
      auto old = existing->second;
      self->handlers->erase(existing);
      if (old.destroy) old.destroy(old.data);
    }
    if (callback) self->handlers->emplace(channel, Handler{callback, data, destroy});
  };
  iface->send_response = [](FlBinaryMessenger*, FlBinaryMessengerResponseHandle* handle,
                            GBytes* bytes, GError**) -> gboolean {
    OnMain();
    auto* response = reinterpret_cast<TestResponse*>(handle);
    g_assert_false(response->done);
    response->done = true;
    response->bytes = bytes ? g_bytes_ref(bytes) : g_bytes_new(nullptr, 0);
    return TRUE;
  };
  iface->send_on_channel = [](FlBinaryMessenger* object, const gchar* channel,
      GBytes* bytes, GCancellable*, GAsyncReadyCallback callback, gpointer) {
    OnMain();
    g_assert_cmpstr(channel, ==, kEvents);
    g_assert_null(callback);
    auto* self = reinterpret_cast<TestMessenger*>(object);
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    g_autoptr(GError) error = nullptr;
    g_autoptr(FlMethodResponse) response = FL_METHOD_CODEC_GET_CLASS(codec)->decode_response(
        FL_METHOD_CODEC(codec), bytes, &error);
    g_assert_no_error(error);
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(response));
    self->events->push_back(fl_value_ref(fl_method_response_get_result(response, nullptr)));
  };
}

static TestResponse* BeginCall(TestMessenger* messenger, const char* channel,
                              const char* name, FlValue* args = nullptr) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(GError) error = nullptr;
  g_autoptr(GBytes) bytes = FL_METHOD_CODEC_GET_CLASS(codec)->encode_method_call(
      FL_METHOD_CODEC(codec), name, args, &error);
  g_assert_no_error(error);
  auto* response = reinterpret_cast<TestResponse*>(g_object_new(test_response_get_type(), nullptr));
  auto& handler = messenger->handlers->at(channel);
  handler.callback(FL_BINARY_MESSENGER(messenger), channel, bytes,
                    FL_BINARY_MESSENGER_RESPONSE_HANDLE(response), handler.data);
  return response;
}
static FlMethodResponse* FinishCall(TestResponse* response) {
  SpinUntil([response] { return response->done; });
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(GError) error = nullptr;
  auto* decoded = FL_METHOD_CODEC_GET_CLASS(codec)->decode_response(
      FL_METHOD_CODEC(codec), response->bytes, &error);
  g_assert_no_error(error);
  g_object_unref(response);
  return decoded;
}
static FlMethodResponse* Call(TestMessenger* messenger, const char* name,
                             FlValue* args = nullptr) {
  return FinishCall(BeginCall(messenger, kControl, name, args));
}
static FlValue* Settings(const char* name, const char* path = "") {
  auto* value = fl_value_new_map();
  fl_value_set_string_take(value, "name", fl_value_new_string(name));
  fl_value_set_string_take(value, "path", fl_value_new_string(path));
  fl_value_set_string_take(value, "autoStart", fl_value_new_bool(false));
  return value;
}
static const char* GetString(FlValue* value, const char* key) {
  return fl_value_get_string(fl_value_lookup_string(value, key));
}

static void TextureTest() {
  auto* registrar = reinterpret_cast<TestRegistrar*>(g_object_new(test_registrar_get_type(), nullptr));
  {
    FrameTexture output(FL_TEXTURE_REGISTRAR(registrar));
    g_assert_true(output.Register());
    g_assert_true(output.Register());
    g_assert_cmpint(output.identifier(), ==, 42);
    std::vector<uint8_t> borrowed{1,2,3,255, 4,5,6,255, 99,99,99,99,
                                7,8,9,255, 10,11,12,255, 99,99,99,99};
    g_assert_true(output.Receive({borrowed.data(), 12, 2, 2}));
    borrowed.assign(borrowed.size(), 0);
    const uint8_t* raster = nullptr;
    uint32_t width = 0, height = 0;
    auto* texture = FL_PIXEL_BUFFER_TEXTURE(registrar->texture);
    auto copy = FL_PIXEL_BUFFER_TEXTURE_GET_CLASS(texture)->copy_pixels;
    g_assert_true(copy(texture, &raster, &width, &height, nullptr));
    g_assert_cmpuint(width, ==, 2);
    g_assert_cmpuint(height, ==, 2);
    const uint8_t expected[] = {1,2,3,255, 4,5,6,255, 7,8,9,255, 10,11,12,255};
    g_assert_cmpmem(raster, 16, expected, sizeof(expected));
    const auto* pinned = raster;
    std::thread producer([&] {
      std::vector<uint8_t> next(16, 128);
      for (int i = 0; i < 2000; ++i) {
        g_assert_true(output.Receive({next.data(), 8, 2, 2}));
        output.Clear();
      }
    });
    producer.join();
    g_assert_cmpmem(pinned, 16, expected, sizeof(expected));
    g_assert_true(copy(texture, &raster, &width, &height, nullptr));
    g_assert_cmpuint(width, ==, 1);
    g_assert_cmpuint(height, ==, 1);
    g_assert_cmpuint(raster[3], ==, 255);
    g_assert_false(output.Receive({nullptr, 4, 1, 1}));
    g_assert_false(output.Receive({borrowed.data(), 4, 2, 1}));
    g_assert_false(output.Receive({borrowed.data(), 4, 0, 1}));
    g_assert_false(output.Receive({borrowed.data(), 4, 1, 4097}));
    output.Notify();
    g_assert_cmpuint(registrar->marks, ==, 1);
  }
  g_assert_null(registrar->texture);
  g_object_unref(registrar);
}

static void HostTest() {
  auto* messenger = reinterpret_cast<TestMessenger*>(g_object_new(test_messenger_get_type(), nullptr));
  auto* registrar = reinterpret_cast<TestRegistrar*>(g_object_new(test_registrar_get_type(), nullptr));
  {
    auto host = std::make_unique<ReceiverHost>(FL_BINARY_MESSENGER(messenger),
                                              FL_TEXTURE_REGISTRAR(registrar));
    g_autoptr(FlMethodResponse) listen = FinishCall(BeginCall(messenger, kEvents, "listen"));
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(listen));
    g_autoptr(FlMethodResponse) snapshot = Call(messenger, "snapshot");
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(snapshot));
    auto* data = fl_method_response_get_result(snapshot, nullptr);
    g_assert_cmpstr(GetString(data, "status"), ==, "stopped");
    g_assert_cmpstr(GetString(data, "path"), ==, "");
    auto* capabilities = fl_value_lookup_string(data, "capabilities");
    g_assert_cmpstr(GetString(capabilities, "platform"), ==, "linux");
    g_assert_false(fl_value_get_bool(fl_value_lookup_string(capabilities, "supportsExecutablePath")));
    g_assert_false(fl_value_get_bool(fl_value_lookup_string(capabilities, "supportsLaunchAtLogin")));
    g_autoptr(FlValue) settings = Settings("Linux Fixture 测试");
    g_autoptr(FlMethodResponse) saved = Call(messenger, "save", settings);
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(saved));
    for (const char* invalid : {"", "bad\nname", "123456789012345678901234567890123456789012345678901"}) {
      g_autoptr(FlValue) args = Settings(invalid);
      g_autoptr(FlMethodResponse) rejected = Call(messenger, "save", args);
      g_assert_true(FL_IS_METHOD_ERROR_RESPONSE(rejected));
    }
    g_autoptr(FlValue) external = Settings("Fixture", "/usr/bin/external");
    g_autoptr(FlMethodResponse) rejected = Call(messenger, "save", external);
    g_assert_true(FL_IS_METHOD_ERROR_RESPONSE(rejected));
    for (int i = 0; i < 3; ++i) {
      g_autoptr(FlMethodResponse) stopped = Call(messenger, "stop");
      g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(stopped));
    }
    std::string discovery_error;
    if (!Discovery::Check(&discovery_error)) {
      // The production Start path must fail before creating a listener when
      // discovery is unavailable, and must never claim the receiver is waiting.
      g_autoptr(FlMethodResponse) failed_start = Call(messenger, "start", settings);
      g_assert_true(FL_IS_METHOD_ERROR_RESPONSE(failed_start));
      g_autoptr(FlMethodResponse) failure_state = Call(messenger, "snapshot");
      auto* failed_data = fl_method_response_get_result(failure_state, nullptr);
      g_assert_cmpstr(GetString(failed_data, "status"), ==, "error");
      g_assert_cmpint(fl_value_get_int(fl_value_lookup_string(failed_data, "pid")), ==, 0);
      for (auto* event : *messenger->events) {
        if (g_strcmp0(GetString(event, "type"), "state") == 0)
          g_assert_cmpstr(GetString(event, "status"), !=, "waiting");
      }
      g_autoptr(FlMethodResponse) stopped = Call(messenger, "stop");
      g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(stopped));
    }
    // A request admitted immediately before destruction gets one main-thread
    // cancellation response. Deferred completions/events must become harmless.
    auto* pending = BeginCall(messenger, kControl, "snapshot");
    host.reset();
    g_autoptr(FlMethodResponse) cancelled = FinishCall(pending);
    g_assert_true(FL_IS_METHOD_ERROR_RESPONSE(cancelled));
    g_assert_cmpstr(fl_method_error_response_get_code(FL_METHOD_ERROR_RESPONSE(cancelled)), ==, "cancelled");
    while (g_main_context_iteration(nullptr, FALSE)) {}
    g_assert_true(messenger->handlers->empty());
    g_assert_null(registrar->texture);
  }
  // Recreate the host with the same XDG directory and assert persistence.
  {
    ReceiverHost host(FL_BINARY_MESSENGER(messenger), FL_TEXTURE_REGISTRAR(registrar));
    g_autoptr(FlMethodResponse) snapshot = Call(messenger, "snapshot");
    auto* data = fl_method_response_get_result(snapshot, nullptr);
    g_assert_cmpstr(GetString(data, "name"), ==, "Linux Fixture 测试");
    g_assert_false(fl_value_get_bool(fl_value_lookup_string(data, "autoStart")));
  }
  while (g_main_context_iteration(nullptr, FALSE)) {}
  g_object_unref(registrar);
  g_object_unref(messenger);
}

static void DiscoveryTest() {
  std::string error;
  if (Discovery::Check(&error)) {
    g_test_skip("Avahi is available; no service is published by this unavailable-daemon fixture.");
    return;
  }
  g_assert_false(error.empty());
  for (int i = 0; i < 3; ++i) {
    Discovery discovery;
    bool asynchronous_failure = false;
    g_assert_false(discovery.Start("Fixture", {2,0,0,0,0,1}, 55555,
        {3,'a','=','b'}, {3,'a','=','b'},
        [&](const std::string&) { asynchronous_failure = true; }, &error));
    g_assert_false(error.empty());
    g_assert_false(asynchronous_failure);
    discovery.Stop();
    discovery.Stop();
  }
  g_test_message("Unavailable Avahi reports: %s", error.c_str());
}

int main(int argc, char** argv) {
  main_thread = std::this_thread::get_id();
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* config = g_dir_make_tmp("flutter-airplay-host-test-XXXXXX", &error);
  g_assert_no_error(error);
  g_setenv("XDG_CONFIG_HOME", config, TRUE);
  g_test_init(&argc, &argv, nullptr);
  g_test_add_func("/linux/texture/borrowed-lifetime-clear", TextureTest);
  g_test_add_func("/linux/host/channels-settings-shutdown", HostTest);
  g_test_add_func("/linux/discovery/unavailable-cleanup", DiscoveryTest);
  const int result = g_test_run();
  g_autofree gchar* ini = g_build_filename(config, "flutter-airplay", "receiver.ini", nullptr);
  g_autofree gchar* directory = g_build_filename(config, "flutter-airplay", nullptr);
  g_unlink(ini);
  g_rmdir(directory);
  g_rmdir(config);
  return result;
}
