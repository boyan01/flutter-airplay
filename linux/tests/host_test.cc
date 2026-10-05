// SPDX-License-Identifier: GPL-3.0-only
#include "host_test_support.h"
#include <cstring>

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
    int snapshots = 0;
    auto host = std::make_unique<ReceiverHost>(FL_BINARY_MESSENGER(messenger),
                                              FL_TEXTURE_REGISTRAR(registrar), [&](FlValue* value) {
      OnMain();
      g_assert_nonnull(fl_value_lookup_string(value, "keepInMenuBar"));
      ++snapshots;
    });
    g_autoptr(FlMethodResponse) listen = FinishCall(BeginCall(messenger, kEvents, "listen"));
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(listen));
    g_autoptr(FlMethodResponse) snapshot = Call(messenger, "snapshot");
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(snapshot));
    auto* data = fl_method_response_get_result(snapshot, nullptr);
    g_assert_cmpstr(GetString(data, "status"), ==, "stopped");
    g_assert_cmpstr(GetString(data, "path"), ==, "");
    g_assert_cmpstr(GetString(data, "videoQuality"), ==, "auto");
    g_assert_cmpuint(fl_value_get_length(fl_value_lookup_string(data, "videoQualities")), ==, 5);
    const char* device_name = GetString(data, "name");
    g_assert_nonnull(device_name);
    g_assert_cmpuint(std::strlen(device_name), >, 0);
    g_assert_cmpuint(std::strlen(device_name), <=, 50);
    g_assert_true(g_utf8_validate(device_name, -1, nullptr));
    if (std::strlen(g_get_host_name()) <= 50)
      g_assert_cmpstr(device_name, ==, g_get_host_name());
    // The initial generated name is persisted even with auto-start disabled.
    g_autoptr(GKeyFile) initial = g_key_file_new();
    g_autofree gchar* settings_path = g_build_filename(g_get_user_config_dir(),
        "flutter-airplay", "receiver.ini", nullptr);
    g_assert_true(g_key_file_load_from_file(initial, settings_path, G_KEY_FILE_NONE, nullptr));
    g_autofree gchar* persisted_name = g_key_file_get_string(initial, "Receiver", "name", nullptr);
    g_assert_cmpstr(persisted_name, ==, device_name);
    auto* capabilities = fl_value_lookup_string(data, "capabilities");
    g_assert_cmpstr(GetString(capabilities, "platform"), ==, "linux");
    g_assert_false(fl_value_get_bool(fl_value_lookup_string(capabilities, "supportsExecutablePath")));
    g_assert_false(fl_value_get_bool(fl_value_lookup_string(capabilities, "supportsLaunchAtLogin")));
    g_autoptr(FlValue) settings = Settings("Linux Fixture 测试");
    fl_value_set_string_take(settings, "videoQuality", fl_value_new_string("1440"));
    fl_value_set_string_take(settings, "keepInMenuBar", fl_value_new_bool(false));
    fl_value_set_string_take(settings, "showOnConnect", fl_value_new_bool(false));
    fl_value_set_string_take(settings, "fullscreenOnConnect", fl_value_new_bool(true));
    fl_value_set_string_take(settings, "alwaysOnTop", fl_value_new_bool(true));
    g_autoptr(FlMethodResponse) saved = Call(messenger, "save", settings);
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(saved));
    SpinUntil([&] { return snapshots >= 2; });
    g_autoptr(FlValue) invalid_quality = Settings("Rejected");
    fl_value_set_string_take(invalid_quality, "videoQuality", fl_value_new_string("invalid"));
    g_autoptr(FlMethodResponse) quality_rejected = Call(messenger, "save", invalid_quality);
    g_assert_true(FL_IS_METHOD_ERROR_RESPONSE(quality_rejected));
    g_autoptr(FlMethodResponse) after_quality = Call(messenger, "snapshot");
    auto* quality_data = fl_method_response_get_result(after_quality, nullptr);
    g_assert_cmpstr(GetString(quality_data, "videoQuality"), ==, "1440");
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
    g_assert_cmpstr(GetString(data, "videoQuality"), ==, "1440");
    g_assert_false(fl_value_get_bool(fl_value_lookup_string(data, "autoStart")));
    g_assert_false(fl_value_get_bool(fl_value_lookup_string(data, "keepInMenuBar")));
    g_assert_false(fl_value_get_bool(fl_value_lookup_string(data, "showOnConnect")));
    g_assert_true(fl_value_get_bool(fl_value_lookup_string(data, "fullscreenOnConnect")));
    g_assert_true(fl_value_get_bool(fl_value_lookup_string(data, "alwaysOnTop")));
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
