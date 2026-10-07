// SPDX-License-Identifier: GPL-3.0-only
// GTK only bridges lifecycle; nativeapi geometry/tray run in Flutter integration tests.
#include "host_test_support.h"
#include "linux/runner/my_application.h"
#include "linux/runner/window_channel.h"
#include <cstdint>
#include <atomic>
#include <cstring>

// Application routing tests stop the activate signal before Flutter creation.
// Linking the real runner still requires its generated plugin entry point.
void fl_register_plugins(FlPluginRegistry*) {}

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
    WindowChannel channel(FL_BINARY_MESSENGER(messenger), window, false, [] { return true; });
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
    WindowChannel channel(FL_BINARY_MESSENGER(messenger), window, scenario != 6,
                          [scenario] { return scenario != 5; });
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
      if (scenario != 2 && scenario != 6) g_assert_false(channel.HideOnClose());
      // A late/repeated success must not undo fallback or explicit activation.
      g_autoptr(FlValue) tray = fl_value_new_bool(true);
      Command(messenger, "finishDesktopStartup", tray);
      g_assert_true(gtk_widget_get_visible(GTK_WIDGET(window)));
      gtk_widget_hide(GTK_WIDGET(window));
      if (scenario != 5) {
        Command(messenger, "finishDesktopStartup", tray);
        g_assert_false(gtk_widget_get_visible(GTK_WIDGET(window)));
      }
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
    WindowChannel channel(FL_BINARY_MESSENGER(messenger), window, true, [probes, delayed_registration] {
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
  auto channel = std::make_unique<WindowChannel>(FL_BINARY_MESSENGER(messenger), window, true, [gate, lifetime] {
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

void PendingReopenTest() {
  auto* messenger = reinterpret_cast<TestMessenger*>(g_object_new(test_messenger_get_type(), nullptr));
  auto* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  g_object_ref_sink(window);
  auto registered = std::make_shared<std::atomic_bool>(false);
  {
    WindowChannel channel(FL_BINARY_MESSENGER(messenger), window, true,
                          [registered] { return registered->load(); });
    Command(messenger, "desktopReady");
    g_autoptr(FlValue) tray = fl_value_new_bool(true);
    auto* pending = BeginCall(messenger, kWindow, "finishDesktopStartup", tray);
    g_assert_false(pending->done);
    g_assert_false(gtk_widget_get_visible(GTK_WIDGET(window)));
    channel.Show();
    g_assert_true(gtk_widget_get_visible(GTK_WIDGET(window)));
    g_assert_true(messenger->events->empty());
    registered->store(true);
    g_autoptr(FlMethodResponse) response = FinishCall(pending);
    g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(response));
    g_assert_true(gtk_widget_get_visible(GTK_WIDGET(window)));
    g_assert_cmpstr(GetString(messenger->events->back(), "method"), ==, "openApp");
  }
  gtk_widget_destroy(GTK_WIDGET(window));
  g_object_unref(window); g_object_unref(messenger);
}

void RemoteLaunch(const char* application_id, const char* argument = nullptr) {
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  g_assert_nonnull(executable);
  const char* argv[] = {executable, "--application-remote", application_id, argument, nullptr};
  g_autoptr(GError) error = nullptr;
  g_autoptr(GSubprocess) process = g_subprocess_newv(argv, G_SUBPROCESS_FLAGS_NONE, &error);
  g_assert_no_error(error);
  g_assert_nonnull(process);
  struct Result { bool done = false; bool success = false; GError* error = nullptr; } result;
  g_subprocess_wait_check_async(process, nullptr, [](GObject* process, GAsyncResult* response, gpointer data) {
    auto* result = static_cast<Result*>(data);
    result->success = g_subprocess_wait_check_finish(G_SUBPROCESS(process), response, &result->error);
    result->done = true;
  }, &result);
  // Dispatch primary-process D-Bus calls while the real secondary process waits.
  SpinUntil([&result] { return result.done; });
  g_assert_no_error(result.error);
  g_assert_true(result.success);
}

void ApplicationRoutingTest(gconstpointer data) {
  if (!g_test_subprocess()) {
    // GtkApplication exports the process-wide /org/gtk/Profiler object. These
    // fixtures register without g_application_run's shutdown, so use a fresh
    // process for each primary application, just as the real runner does.
    g_test_trap_subprocess(nullptr, 15 * G_TIME_SPAN_SECOND, G_TEST_SUBPROCESS_DEFAULT);
    g_test_trap_assert_passed();
    return;
  }
  const bool login_start = GPOINTER_TO_INT(data);
  g_autoptr(MyApplication) application = my_application_new();
  g_autofree gchar* id = g_strdup_printf("tech.soit.flutterairplay.WindowTest%d", login_start);
  g_application_set_application_id(G_APPLICATION(application), id);
  g_assert_true(g_application_get_flags(G_APPLICATION(application)) & G_APPLICATION_HANDLES_COMMAND_LINE);
  struct State { unsigned activations = 0; GtkWidget* window = nullptr; } state;
  g_signal_connect(application, "activate", G_CALLBACK(+[](GApplication* application, gpointer data) {
    auto* state = static_cast<State*>(data);
    ++state->activations;
    if (!state->window) state->window = gtk_application_window_new(GTK_APPLICATION(application));
    // Mock only Flutter/view creation; registration, argument forwarding and
    // command-line routing all execute the production MyApplication code.
    g_signal_stop_emission_by_name(application, "activate");
  }), &state);
  g_autoptr(GError) error = nullptr;
  g_assert_true(g_application_register(G_APPLICATION(application), nullptr, &error));
  g_assert_no_error(error);
  g_assert_false(g_application_get_is_remote(G_APPLICATION(application)));
  RemoteLaunch(id, login_start ? "--launch-at-login" : nullptr);
  g_assert_cmpuint(state.activations, ==, 1);
  RemoteLaunch(id, "--launch-at-login");
  g_assert_cmpuint(state.activations, ==, 1);
  RemoteLaunch(id);
  g_assert_cmpuint(state.activations, ==, 2);
  // Match the complete host flag rather than treating a prefix as a login.
  RemoteLaunch(id, "--launch-at-login-extra");
  g_assert_cmpuint(state.activations, ==, 3);
  RemoteLaunch(id, "--launch-at-login");
  g_assert_cmpuint(state.activations, ==, 3);
  g_application_activate(G_APPLICATION(application));
  g_assert_cmpuint(state.activations, ==, 4);
  gtk_widget_destroy(state.window);
}
}  // namespace
int main(int argc, char** argv) {
  if (argc >= 3 && !std::strcmp(argv[1], "--application-remote")) {
    g_autoptr(MyApplication) application = my_application_new();
    g_application_set_application_id(G_APPLICATION(application), argv[2]);
    return g_application_run(G_APPLICATION(application), argc - 2, argv + 2);
  }
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
  g_test_add_data_func("/window/startup-manual-visible", GINT_TO_POINTER(6), StartupTest);
  g_test_add_data_func("/window/startup-host-present-item-missing", GINT_TO_POINTER(0), RegistrationTest);
  g_test_add_data_func("/window/startup-delayed-item-registration", GINT_TO_POINTER(1), RegistrationTest);
  g_test_add_data_func("/window/startup-destroy-pending-probe", GINT_TO_POINTER(1), CancelRegistrationTest);
  g_test_add_data_func("/window/startup-fallback-pending-probe", GINT_TO_POINTER(0), CancelRegistrationTest);
  g_test_add_func("/window/startup-reopen-pending-probe", PendingReopenTest);
  g_test_add_data_func("/window/application-manual-activation-routing", GINT_TO_POINTER(0), ApplicationRoutingTest);
  g_test_add_data_func("/window/application-login-activation-routing", GINT_TO_POINTER(1), ApplicationRoutingTest);
  return g_test_run();
}
