// SPDX-License-Identifier: GPL-3.0-only
// Shared in-process Flutter messenger/texture fixtures for native host tests.
#pragma once
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
constexpr char kControl[] = "org.airplayreceiver/platform";
constexpr char kEvents[] = "org.airplayreceiver/events";
constexpr char kWindow[] = "tech.soit.flutterairplay/window";
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
    g_assert_null(callback);
    auto* self = reinterpret_cast<TestMessenger*>(object);
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    g_autoptr(GError) error = nullptr;
    if (g_strcmp0(channel, kWindow) == 0) {
      gchar* method = nullptr;
      FlValue* args = nullptr;
      g_assert_true(FL_METHOD_CODEC_GET_CLASS(codec)->decode_method_call(
          FL_METHOD_CODEC(codec), bytes, &method, &args, &error));
      g_assert_no_error(error);
      auto* event = fl_value_new_map();
      fl_value_set_string_take(event, "method", fl_value_new_string(method));
      if (args) { fl_value_set_string(event, "args", args); fl_value_unref(args); }
      g_free(method);
      self->events->push_back(event);
      return;
    }
    g_assert_cmpstr(channel, ==, kEvents);
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

