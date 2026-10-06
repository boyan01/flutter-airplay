// SPDX-License-Identifier: GPL-3.0-only
#include "host_test_support.h"
#include <cstring>
#include "../../native/include/airplay/receiver.h"

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
  uint64_t handle = 0;
  {
    int snapshots = 0;
    ReceiverHost host(FL_BINARY_MESSENGER(messenger), FL_TEXTURE_REGISTRAR(registrar), [&](FlValue* value) {
      OnMain(); g_assert_nonnull(fl_value_lookup_string(value, "keepInMenuBar")); ++snapshots;
    });
    g_autoptr(FlMethodResponse) bootstrap = Call(messenger, "bootstrap");
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(bootstrap));
    handle = fl_value_get_int(fl_value_lookup_string(fl_method_response_get_result(bootstrap, nullptr), "handle"));
    g_assert_cmpint(handle, >, 0);
    char error[512]{};
    auto* initial = airplay_receiver_snapshot(handle, error, sizeof(error)); g_assert_nonnull(initial);
    g_assert_cmpint(initial->status, ==, AIRPLAY_RECEIVER_STOPPED);
    g_assert_cmpstr(initial->platform, ==, "linux"); g_assert_cmpint(initial->texture_id, ==, 42);
    airplay_receiver_free_snapshot(initial);
    const std::string name = "Linux Fixture 测试";
    AirplayReceiverSettings settings{};
    settings.fields = AIRPLAY_SETTING_NAME | AIRPLAY_SETTING_FAST_PAIRING | AIRPLAY_SETTING_VIDEO_QUALITY;
    settings.name = name.data(); settings.name_size = name.size(); settings.fast_pairing = true; settings.video_quality = AIRPLAY_VIDEO_1440;
    g_assert_true(airplay_receiver_save(handle, &settings, error, sizeof(error)));
    SpinUntil([&] { return snapshots > 0; });
    // Settings writes now belong to Dart, rather than GTK/C++.
    g_autofree gchar* path = g_build_filename(g_get_user_config_dir(), "flutter-airplay", "receiver.ini", nullptr);
    g_autoptr(GKeyFile) preferences = g_key_file_new();
    g_assert_true(g_key_file_load_from_file(preferences, path, G_KEY_FILE_NONE, nullptr));
    g_assert_false(g_key_file_has_key(preferences, "Receiver", "name", nullptr));
    g_assert_true(g_key_file_has_key(preferences, "Receiver", "identity", nullptr));
    std::string discovery_error;
    if (!Discovery::Check(&discovery_error)) {
      g_assert_false(airplay_receiver_start(handle, UINT64_MAX, error, sizeof(error)));
      auto* failed = airplay_receiver_snapshot(handle, error, sizeof(error)); g_assert_nonnull(failed);
      g_assert_cmpint(failed->status, ==, AIRPLAY_RECEIVER_ERROR); g_assert_cmpint(failed->pid, ==, 0);
      airplay_receiver_free_snapshot(failed);
    }
    g_assert_true(airplay_receiver_stop(handle, error, sizeof(error)));
  }
  char error[512]{};
  g_assert_null(airplay_receiver_snapshot(handle, error, sizeof(error)));
  g_assert_true(strlen(error) > 0);

  while (g_main_context_iteration(nullptr, FALSE)) {}
  g_assert_true(messenger->handlers->empty()); g_assert_null(registrar->texture);
  g_object_unref(registrar); g_object_unref(messenger);
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
  g_test_add_func("/linux/host/ffi-bootstrap-settings-shutdown", HostTest);
  g_test_add_func("/linux/discovery/unavailable-cleanup", DiscoveryTest);
  const int result = g_test_run();
  g_autofree gchar* ini = g_build_filename(config, "flutter-airplay", "receiver.ini", nullptr);
  g_autofree gchar* directory = g_build_filename(config, "flutter-airplay", nullptr);
  g_unlink(ini);
  g_rmdir(directory);
  g_rmdir(config);
  return result;
}
