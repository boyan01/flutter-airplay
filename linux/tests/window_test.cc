// SPDX-License-Identifier: GPL-3.0-only
// GTK only bridges lifecycle; nativeapi geometry/tray run in Flutter integration tests.
#include "host_test_support.h"
#include "linux/runner/window_channel.h"
#include <cstdint>
#include <atomic>

namespace {
void Command(TestMessenger* messenger, const char* method, FlValue* args = nullptr) {
  g_autoptr(FlMethodResponse) response = FinishCall(BeginCall(messenger, kWindow, method, args));
  g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(response));
}
void WindowTest() {
  auto* messenger = reinterpret_cast<TestMessenger*>(g_object_new(test_messenger_get_type(), nullptr));
  auto* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  g_object_ref_sink(window);
  gtk_widget_show(GTK_WIDGET(window));
  {
    WindowChannel channel(FL_BINARY_MESSENGER(messenger), window, [] { return true; });
    gtk_widget_hide(GTK_WIDGET(window));
    g_autoptr(FlMethodResponse) handle_response =
        FinishCall(BeginCall(messenger, kWindow, "getNativeWindowHandle", nullptr));
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(handle_response));
    auto* handle = fl_method_success_response_get_result(FL_METHOD_SUCCESS_RESPONSE(handle_response));
    g_assert_cmpint(fl_value_get_int(handle), ==, reinterpret_cast<intptr_t>(window));
    gtk_widget_show(GTK_WIDGET(window));
    g_assert_false(channel.HideOnClose());
    Command(messenger, "desktopReady");
    g_autoptr(FlValue) tray = fl_value_new_bool(true);
    Command(messenger, "finishDesktopStartup", tray);
    g_autoptr(FlValue) hide = fl_value_new_bool(true);
    Command(messenger, "setClosePolicy", hide);
    g_assert_true(channel.HideOnClose());
    g_assert_cmpstr(GetString(messenger->events->back(), "method"), ==, "closeRequested");
    g_assert_true(gtk_widget_get_visible(GTK_WIDGET(window)));
    channel.Show();
    g_assert_cmpstr(GetString(messenger->events->back(), "method"), ==, "openApp");
    GdkEventWindowState state{};
    state.type = GDK_WINDOW_STATE;
    state.changed_mask = GDK_WINDOW_STATE_FULLSCREEN;
    state.new_window_state = GDK_WINDOW_STATE_FULLSCREEN;
    gboolean handled;
    g_signal_emit_by_name(window, "window-state-event", &state, &handled);
    g_assert_cmpstr(GetString(messenger->events->back(), "method"), ==, "windowStateChanged");
    g_autoptr(FlValue) close = fl_value_new_bool(false);
    Command(messenger, "setClosePolicy", close);
    g_assert_false(channel.HideOnClose());
  }
  gtk_widget_destroy(GTK_WIDGET(window));
  g_object_unref(window); g_object_unref(messenger);
}
void StartupTest(gconstpointer data) {
  const auto scenario = GPOINTER_TO_INT(data);
  auto* messenger = reinterpret_cast<TestMessenger*>(g_object_new(test_messenger_get_type(), nullptr));
  auto* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  g_object_ref_sink(window);
  {
    WindowChannel channel(FL_BINARY_MESSENGER(messenger), window, [scenario] { return scenario != 5; });
    g_assert_false(gtk_widget_get_visible(GTK_WIDGET(window)));
    Command(messenger, "desktopReady");
    g_autoptr(FlValue) keep_running = fl_value_new_bool(true);
    Command(messenger, "setClosePolicy", keep_running);
    // Early method-channel readiness must not make the top-level visible.
    g_assert_false(gtk_widget_get_visible(GTK_WIDGET(window)));
    if (scenario == 2) channel.Show();
    if (scenario == 4) {
      g_autoptr(FlValue) tray = fl_value_new_bool(true);
      Command(messenger, "finishDesktopStartup", tray);
      g_assert_false(gtk_widget_get_visible(GTK_WIDGET(window)));
    }
    if (scenario == 3) {
      const auto deadline = g_get_monotonic_time() + 12 * G_TIME_SPAN_SECOND;
      while (!gtk_widget_get_visible(GTK_WIDGET(window)) && g_get_monotonic_time() < deadline) {
        while (g_main_context_iteration(nullptr, FALSE)) {}
        g_usleep(1000);
      }
    } else {
      g_autoptr(FlValue) tray = fl_value_new_bool(scenario != 1 && scenario != 4);
      g_autoptr(FlMethodResponse) response = FinishCall(BeginCall(messenger, kWindow, "finishDesktopStartup", tray));
      g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(response));
      auto* result = fl_method_success_response_get_result(FL_METHOD_SUCCESS_RESPONSE(response));
      g_assert_cmpint(fl_value_get_bool(result), ==, scenario != 1 && scenario != 4 && scenario != 5);
    }
    g_assert_cmpint(gtk_widget_get_visible(GTK_WIDGET(window)), ==, scenario != 0);
    if (scenario != 0) {
      g_assert_cmpstr(GetString(messenger->events->back(), "method"), ==, "openApp");
      if (scenario != 2) g_assert_false(channel.HideOnClose());
      // A late/repeated success must not undo fallback or explicit activation.
      g_autoptr(FlValue) tray = fl_value_new_bool(true);
      Command(messenger, "finishDesktopStartup", tray);
      g_assert_true(gtk_widget_get_visible(GTK_WIDGET(window)));
      gtk_widget_hide(GTK_WIDGET(window));
      channel.Show();
      g_assert_true(gtk_widget_get_visible(GTK_WIDGET(window)));
    }
  }
  gtk_widget_destroy(GTK_WIDGET(window));
  g_object_unref(window); g_object_unref(messenger);
}
void RegistrationTest(gconstpointer data) {
  const bool delayed_registration = GPOINTER_TO_INT(data);
  auto* messenger = reinterpret_cast<TestMessenger*>(g_object_new(test_messenger_get_type(), nullptr));
  auto* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  g_object_ref_sink(window);
  auto probes = std::make_shared<std::atomic_int>(0);
  {
    // The host is available, but this app's item is initially missing. An
    // unrelated application's registration must not complete our startup.
    WindowChannel channel(FL_BINARY_MESSENGER(messenger), window, [probes, delayed_registration] {
      return ++*probes >= 3 && delayed_registration;
    });
    Command(messenger, "desktopReady");
    g_autoptr(FlValue) enabled = fl_value_new_bool(true);
    Command(messenger, "setClosePolicy", enabled);
    auto* pending = BeginCall(messenger, kWindow, "finishDesktopStartup", enabled);
    g_assert_false(pending->done);
    g_assert_false(gtk_widget_get_visible(GTK_WIDGET(window)));
    // Normal main-context work must run while startup awaits registration.
    bool idle_ran = false;
    g_idle_add([](gpointer data) -> gboolean {
      *static_cast<bool*>(data) = true; return G_SOURCE_REMOVE;
    }, &idle_ran);
    g_autoptr(FlMethodResponse) response = FinishCall(pending);
    g_assert_true(idle_ran);
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(response));
    auto* result = fl_method_success_response_get_result(FL_METHOD_SUCCESS_RESPONSE(response));
    g_assert_cmpint(fl_value_get_bool(result), ==, delayed_registration);
    g_assert_cmpint(probes->load(), >=, 3);
    g_assert_cmpint(gtk_widget_get_visible(GTK_WIDGET(window)), ==, !delayed_registration);
    if (!delayed_registration) g_assert_false(channel.HideOnClose());
  }
  gtk_widget_destroy(GTK_WIDGET(window));
  g_object_unref(window); g_object_unref(messenger);
}
void CancelRegistrationTest(gconstpointer data) {
  const bool destroy_pending = GPOINTER_TO_INT(data);
  auto* messenger = reinterpret_cast<TestMessenger*>(g_object_new(test_messenger_get_type(), nullptr));
  auto* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  g_object_ref_sink(window);
  struct Gate { std::atomic_bool started{false}, release{false}; };
  auto gate = std::make_shared<Gate>();
  auto lifetime = std::make_shared<int>(0);
  std::weak_ptr<int> task_lifetime = lifetime;
  auto channel = std::make_unique<WindowChannel>(FL_BINARY_MESSENGER(messenger), window, [gate, lifetime] {
    gate->started = true;
    // Block only this test worker; the GTK thread remains available to destroy
    // the channel or run the same fallback used by the startup watchdog.
    while (!gate->release) g_usleep(1000);
    return true;
  });
  lifetime.reset();
  g_autoptr(FlValue) enabled = fl_value_new_bool(true);
  auto* pending = BeginCall(messenger, kWindow, "finishDesktopStartup", enabled);
  SpinUntil([gate] { return gate->started.load(); });
  g_assert_false(pending->done);
  if (!destroy_pending) channel->FinishDesktopStartup(false);
  channel.reset();
  // Retain the response through the queued completion. TestMessenger asserts
  // that send_response is never called twice for the same response handle.
  g_object_ref(pending);
  g_autoptr(FlMethodResponse) response = FinishCall(pending);
  if (destroy_pending) {
    g_assert_true(FL_IS_METHOD_ERROR_RESPONSE(response));
    g_assert_cmpstr(fl_method_error_response_get_code(FL_METHOD_ERROR_RESPONSE(response)), ==, "window_closed");
  } else {
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(response));
    g_assert_false(fl_value_get_bool(fl_method_success_response_get_result(FL_METHOD_SUCCESS_RESPONSE(response))));
  }
  gate->release = true;
  // Task data is destroyed after its cancelled completion has been dispatched.
  SpinUntil([&task_lifetime] { return task_lifetime.expired(); });
  g_assert_true(pending->done);
  g_object_unref(pending);
  gtk_widget_destroy(GTK_WIDGET(window));
  g_object_unref(window); g_object_unref(messenger);
}
}  // namespace
int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  gtk_init(&argc, &argv);
  main_thread = std::this_thread::get_id();
  g_test_add_func("/window/lifecycle-bridge", WindowTest);
  g_test_add_data_func("/window/startup-tray-hidden", GINT_TO_POINTER(0), StartupTest);
  g_test_add_data_func("/window/startup-no-tray-fallback", GINT_TO_POINTER(1), StartupTest);
  g_test_add_data_func("/window/startup-reopen", GINT_TO_POINTER(2), StartupTest);
  g_test_add_data_func("/window/startup-timeout", GINT_TO_POINTER(3), StartupTest);
  g_test_add_data_func("/window/startup-late-failure", GINT_TO_POINTER(4), StartupTest);
  g_test_add_data_func("/window/startup-no-tray-host", GINT_TO_POINTER(5), StartupTest);
  g_test_add_data_func("/window/startup-host-present-item-missing", GINT_TO_POINTER(0), RegistrationTest);
  g_test_add_data_func("/window/startup-delayed-item-registration", GINT_TO_POINTER(1), RegistrationTest);
  g_test_add_data_func("/window/startup-destroy-pending-probe", GINT_TO_POINTER(1), CancelRegistrationTest);
  g_test_add_data_func("/window/startup-fallback-pending-probe", GINT_TO_POINTER(0), CancelRegistrationTest);
  return g_test_run();
}
