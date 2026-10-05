// SPDX-License-Identifier: GPL-3.0-only
// Real GTK windows and AppIndicator/DBusMenu on an isolated session bus/display.
#include "host_test_support.h"
#include "linux/runner/window_channel.h"
#include <algorithm>
#include <cmath>
#include <cstring>

namespace {
std::string item_owner, item_path;
bool name_owned = false;
constexpr char watcher_xml[] = R"(<node><interface name="org.kde.StatusNotifierWatcher">
<method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
<property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
<property name="RegisteredStatusNotifierItems" type="as" access="read"/>
<property name="ProtocolVersion" type="i" access="read"/>
</interface></node>)";

GVariant* RemoteCall(GDBusConnection* bus, const char* path, const char* interface,
                     const char* method, GVariant* args, GError** error = nullptr) {
  struct Result { bool done = false; GVariant* value = nullptr; GError* error = nullptr; } result;
  g_dbus_connection_call(bus, item_owner.c_str(), path, interface, method, args,
      nullptr, G_DBUS_CALL_FLAGS_NONE, 5000, nullptr,
      [](GObject* object, GAsyncResult* pending, gpointer data) {
        auto* result = static_cast<Result*>(data);
        result->value = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), pending, &result->error);
        result->done = true;
      }, &result);
  SpinUntil([&] { return result.done; });
  if (error) { *error = result.error; return result.value; }
  g_assert_no_error(result.error);
  g_assert_nonnull(result.value);
  return result.value;
}

int FindMenuItem(GVariant* node, const char* label) {
  g_autoptr(GVariant) id = g_variant_get_child_value(node, 0);
  g_autoptr(GVariant) properties = g_variant_get_child_value(node, 1);
  const gchar* text = nullptr;
  if (g_variant_lookup(properties, "label", "&s", &text) && !std::strcmp(text, label))
    return g_variant_get_int32(id);
  g_autoptr(GVariant) children = g_variant_get_child_value(node, 2);
  for (gsize i = 0; i < g_variant_n_children(children); ++i) {
    g_autoptr(GVariant) wrapped = g_variant_get_child_value(children, i);
    g_autoptr(GVariant) child = g_variant_get_variant(wrapped);
    const int found = FindMenuItem(child, label);
    if (found >= 0) return found;
  }
  return -1;
}

void TrayAction(GDBusConnection* bus, const char* menu, const char* label) {
  g_test_message("Tray action: %s", label);
  guint latest_revision = 0;
  const guint subscription = g_dbus_connection_signal_subscribe(bus, item_owner.c_str(),
      "com.canonical.dbusmenu", "LayoutUpdated", menu, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      [](GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*,
         GVariant* args, gpointer data) {
        guint revision; gint parent;
        g_variant_get(args, "(ui)", &revision, &parent);
        auto* latest = static_cast<guint*>(data);
        *latest = std::max(*latest, revision);
      }, &latest_revision, nullptr);
  // Window-state callbacks can replace the exported menu while a D-Bus reply
  // is in flight. Follow LayoutUpdated revisions as a real tray client does.
  for (int attempt = 0; attempt < 10; ++attempt) {
    g_autoptr(GVariant) layout = RemoteCall(bus, menu, "com.canonical.dbusmenu", "GetLayout",
        g_variant_new("(ii@as)", 0, -1, g_variant_new_strv(nullptr, 0)));
    g_autoptr(GVariant) version = g_variant_get_child_value(layout, 0);
    const guint revision = g_variant_get_uint32(version);
    if (latest_revision > revision) continue;
    g_autoptr(GVariant) root = g_variant_get_child_value(layout, 1);
    const int id = FindMenuItem(root, label);
    g_assert_cmpint(id, >=, 0);
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) clicked = RemoteCall(bus, menu, "com.canonical.dbusmenu", "Event",
        g_variant_new("(isvu)", id, "clicked", g_variant_new_int32(0), 0u), &error);
    if (error) {
      // Retry only an explicitly invalidated item, never other D-Bus failures.
      g_assert_nonnull(g_strstr_len(error->message, -1, "does not refer to a menu item"));
      g_assert_cmpuint(latest_revision, >, revision);
      continue;
    }
    g_assert_nonnull(clicked);
    g_dbus_connection_signal_unsubscribe(bus, subscription);
    return;
  }
  g_dbus_connection_signal_unsubscribe(bus, subscription);
  g_error("Tray menu did not stabilize for action %s", label);
}

void Command(TestMessenger* messenger, const char* method, FlValue* args = nullptr) {
  g_autoptr(FlMethodResponse) response = FinishCall(BeginCall(messenger, kWindow, method, args));
  g_assert_true(FL_IS_METHOD_SUCCESS_RESPONSE(response));
}
void Mode(TestMessenger* messenger, int width, int height) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "mode", fl_value_new_string(width ? "player" : "home"));
  fl_value_set_string_take(args, "width", fl_value_new_int(width));
  fl_value_set_string_take(args, "height", fl_value_new_int(height));
  Command(messenger, "setMode", args);
}
void CheckSize(GtkWindow* window, int expected_width, int expected_height) {
  SpinUntil([&] {
    int width, height; gtk_window_get_size(window, &width, &height);
    return std::abs(width - expected_width) <= 2 && std::abs(height - expected_height) <= 2;
  });
}

void WindowTest() {
  auto* messenger = reinterpret_cast<TestMessenger*>(g_object_new(test_messenger_get_type(), nullptr));
  auto* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  g_object_ref_sink(window);
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_default_size(window, 440, 560);
  auto* overlay = gtk_overlay_new();
  auto* input = gtk_drawing_area_new();
  gtk_container_add(GTK_CONTAINER(overlay), input);
  AddWindowResizeHandles(GTK_OVERLAY(overlay), window);
  gtk_container_add(GTK_CONTAINER(window), overlay);
  gtk_widget_show_all(GTK_WIDGET(window));
  {
    WindowChannel channel(FL_BINARY_MESSENGER(messenger), window, false);
    g_assert_false(gtk_window_get_decorated(window));
    g_assert_false(channel.HideOnClose());  // No tray: closing must not strand the user.
    Mode(messenger, 0, 0); CheckSize(window, 440, 560);
    auto* monitor = gdk_display_get_monitor_at_window(gtk_widget_get_display(GTK_WIDGET(window)),
        gtk_widget_get_window(GTK_WIDGET(window)));
    GdkRectangle work; gdk_monitor_get_workarea(monitor, &work);
    const int width = std::min(int(work.width * .8), int(work.height * .8 * 16 / 9));
    Mode(messenger, 1920, 1080); CheckSize(window, width, int(width * 9.0 / 16));
    Mode(messenger, 1080, 1920);
    const int portrait_width = std::min(int(work.width * .8), int(work.height * .8 * 9 / 16));
    CheckSize(window, portrait_width, int(portrait_width * 16.0 / 9));
    for (int rotation = 0; rotation < 3; ++rotation) {
      Mode(messenger, 1920, 1080); CheckSize(window, width, int(width * 9.0 / 16));
      Mode(messenger, 1080, 1920); CheckSize(window, portrait_width, int(portrait_width * 16.0 / 9));
    }
    Mode(messenger, 0, 0); CheckSize(window, 440, 560);
    GdkEventWindowState state{};
    state.type = GDK_WINDOW_STATE;
    state.new_window_state = GDK_WINDOW_STATE_FULLSCREEN;
    gboolean handled;
    g_signal_emit_by_name(window, "window-state-event", &state, &handled);
    Mode(messenger, 1920, 1080); CheckSize(window, 440, 560);
    state.new_window_state = static_cast<GdkWindowState>(0);
    g_signal_emit_by_name(window, "window-state-event", &state, &handled);
    SpinUntil([&] {
      int w, h; gtk_window_get_size(window, &w, &h);
      return std::abs(double(w) / h - 16.0 / 9) < .005;
    });
    g_assert_false(messenger->events->empty());
  }
  gtk_widget_destroy(GTK_WIDGET(window));
  g_object_unref(window);
  g_object_unref(messenger);
}

void TrayTest() {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  g_assert_no_error(error);
  g_autoptr(GDBusNodeInfo) info = g_dbus_node_info_new_for_xml(watcher_xml, &error);
  g_assert_no_error(error);
  const GDBusInterfaceVTable vtable = {
    [](GDBusConnection*, const gchar* sender, const gchar*, const gchar*, const gchar*,
       GVariant* args, GDBusMethodInvocation* call, gpointer) {
      const gchar* service; g_variant_get(args, "(&s)", &service);
      item_owner = service[0] == '/' ? sender : service;
      item_path = service[0] == '/' ? service : "/StatusNotifierItem";
      g_dbus_method_invocation_return_value(call, nullptr);
    },
    [](GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar* property, GError**, gpointer) -> GVariant* {
      if (!std::strcmp(property, "IsStatusNotifierHostRegistered")) return g_variant_new_boolean(TRUE);
      if (!std::strcmp(property, "ProtocolVersion")) return g_variant_new_int32(0);
      return g_variant_new_strv(nullptr, 0);
    }, nullptr, {0}
  };
  const guint registration = g_dbus_connection_register_object(bus, "/StatusNotifierWatcher",
      info->interfaces[0], &vtable, nullptr, nullptr, &error);
  g_assert_no_error(error);
  const guint name = g_bus_own_name_on_connection(bus, "org.kde.StatusNotifierWatcher", G_BUS_NAME_OWNER_FLAGS_NONE,
      [](GDBusConnection*, const gchar*, gpointer) { name_owned = true; }, nullptr, nullptr, nullptr);
  SpinUntil([] { return name_owned; });
  auto* messenger = reinterpret_cast<TestMessenger*>(g_object_new(test_messenger_get_type(), nullptr));
  auto* window = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  g_object_ref_sink(window);
  gtk_widget_show(GTK_WIDGET(window));
  {
    WindowChannel channel(FL_BINARY_MESSENGER(messenger), window);
    g_autoptr(FlValue) snapshot = fl_value_new_map();
    fl_value_set_string_take(snapshot, "name", fl_value_new_string("Synthetic tray fixture"));
    fl_value_set_string_take(snapshot, "status", fl_value_new_string("waiting"));
    fl_value_set_string_take(snapshot, "keepInMenuBar", fl_value_new_bool(true));
    channel.UpdateSnapshot(snapshot);
    g_autoptr(FlValue) strings = fl_value_new_map();
    for (const char* key : {"openApp", "receive", "settings", "logs", "quitApp", "actualSize", "fitScreen"})
      fl_value_set_string_take(strings, key, fl_value_new_string(key));
    Command(messenger, "setStrings", strings);
    SpinUntil([&] { return !item_owner.empty() && channel.HideOnClose(); });
    g_assert_false(gtk_widget_get_visible(GTK_WIDGET(window)));
    g_autoptr(GVariant) property = RemoteCall(bus, item_path.c_str(), "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.kde.StatusNotifierItem", "Menu"));
    g_autoptr(GVariant) wrapped = g_variant_get_child_value(property, 0);
    g_autoptr(GVariant) menu_value = g_variant_get_variant(wrapped);
    std::string menu = g_variant_get_string(menu_value, nullptr);
    TrayAction(bus, menu.c_str(), "openApp");
    g_assert_true(gtk_widget_get_visible(GTK_WIDGET(window)));
    TrayAction(bus, menu.c_str(), "receive");
    g_assert_cmpstr(GetString(messenger->events->back(), "method"), ==, "toggleReceiver");
    fl_value_set_string_take(snapshot, "keepInMenuBar", fl_value_new_bool(false));
    channel.UpdateSnapshot(snapshot);
    g_assert_false(channel.HideOnClose());
    fl_value_set_string_take(snapshot, "keepInMenuBar", fl_value_new_bool(true));
    channel.UpdateSnapshot(snapshot);
    g_assert_true(channel.HideOnClose());
    fl_value_set_string_take(snapshot, "status", fl_value_new_string("streaming"));
    fl_value_set_string_take(snapshot, "videoWidth", fl_value_new_int(1920));
    fl_value_set_string_take(snapshot, "videoHeight", fl_value_new_int(1080));
    channel.UpdateSnapshot(snapshot);
    g_assert_true(gtk_widget_get_visible(GTK_WIDGET(window)));  // showOnConnect defaults on.
    Mode(messenger, 640, 360);
    TrayAction(bus, menu.c_str(), "actualSize");
    const int scale = gtk_widget_get_scale_factor(GTK_WIDGET(window));
    CheckSize(window, 640 / scale, 360 / scale);
    TrayAction(bus, menu.c_str(), "fitScreen");
    auto* monitor = gdk_display_get_monitor_at_window(gtk_widget_get_display(GTK_WIDGET(window)),
        gtk_widget_get_window(GTK_WIDGET(window)));
    GdkRectangle work; gdk_monitor_get_workarea(monitor, &work);
    const int fitted_width = std::min(int(work.width * .8), int(work.height * .8 * 16 / 9));
    CheckSize(window, fitted_width, int(fitted_width * 9.0 / 16));
    fl_value_set_string_take(snapshot, "videoWidth", fl_value_new_int(0));
    fl_value_set_string_take(snapshot, "videoHeight", fl_value_new_int(0));
    channel.UpdateSnapshot(snapshot);
    SpinUntil([&] { return !gtk_widget_get_visible(GTK_WIDGET(window)); });
    channel.Show();
    fl_value_set_string_take(snapshot, "videoWidth", fl_value_new_int(1920));
    fl_value_set_string_take(snapshot, "videoHeight", fl_value_new_int(1080));
    channel.UpdateSnapshot(snapshot);
    g_assert_true(channel.HideOnClose());
    g_assert_cmpstr(GetString(messenger->events->back(), "method"), ==, "disconnectSession");
    g_bus_unown_name(name);
    SpinUntil([&] { return gtk_widget_get_visible(GTK_WIDGET(window)); });
    g_assert_false(channel.HideOnClose());  // Lost watcher restores the window.
    name_owned = false;
    item_owner.clear();
    const guint restored_name = g_bus_own_name_on_connection(bus, "org.kde.StatusNotifierWatcher", G_BUS_NAME_OWNER_FLAGS_NONE,
        [](GDBusConnection*, const gchar*, gpointer) { name_owned = true; }, nullptr, nullptr, nullptr);
    SpinUntil([&] { return name_owned && !item_owner.empty() && channel.HideOnClose(); });
    channel.Show();
    bool closed = false;
    g_signal_connect(window, "delete-event", G_CALLBACK(+[](GtkWidget*, GdkEvent*, gpointer data) -> gboolean {
      return static_cast<WindowChannel*>(data)->HideOnClose();
    }), &channel);
    g_signal_connect(window, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer data) {
      *static_cast<bool*>(data) = true;
    }), &closed);
    Command(messenger, "quitApp");
    SpinUntil([&] { return closed; });
    g_bus_unown_name(restored_name);
  }
  gtk_widget_destroy(GTK_WIDGET(window));
  g_object_unref(window);
  g_object_unref(messenger);
  g_dbus_connection_unregister_object(bus, registration);
}
}  // namespace

int main(int argc, char** argv) {
  main_thread = std::this_thread::get_id();
  gtk_init(&argc, &argv);
  g_test_init(&argc, &argv, nullptr);
  g_test_add_func("/linux/window/mode-rotation-fullscreen-cleanup", WindowTest);
  g_test_add_func("/linux/tray/dbus-menu-close-connect-loss", TrayTest);
  return g_test_run();
}
