// SPDX-License-Identifier: GPL-3.0-only
#include "window_channel.h"
#include <cstring>
#include <cstdint>
#include <utility>

namespace {
bool TrayHostAvailable() {
  // nativeapi 0.4 only tests session-bus connectivity. An actual host is needed
  // to expose the icon/menu (for example GNOME without an indicator extension
  // has a session bus but no tray).
  g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (!bus) return false;
  for (const char* watcher : {"org.kde.StatusNotifierWatcher", "com.canonical.StatusNotifierWatcher"}) {
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(bus,
        watcher, "/StatusNotifierWatcher", "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", watcher, "IsStatusNotifierHostRegistered"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 1000, nullptr, nullptr);
    if (!reply) continue;
    g_autoptr(GVariant) value = nullptr;
    g_variant_get(reply, "(v)", &value);
    if (g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN) && g_variant_get_boolean(value)) return true;
  }
  return false;
}
}  // namespace

WindowChannel::WindowChannel(FlBinaryMessenger* messenger, GtkWindow* window,
                             std::function<bool()> tray_host_available)
    : messenger_(FL_BINARY_MESSENGER(g_object_ref(messenger))),
      window_(GTK_WINDOW(g_object_ref(window))),
      tray_host_available_(tray_host_available ? std::move(tray_host_available) : TrayHostAvailable) {
  state_handler_ = g_signal_connect(window_, "window-state-event",
      G_CALLBACK(+[](GtkWidget*, GdkEventWindowState* event, gpointer data) -> gboolean {
        // nativeapi already reports maximize/restore. Only fullscreen lacks
        // a dedicated event in its current Dart contract.
        if (!(event->changed_mask & GDK_WINDOW_STATE_FULLSCREEN)) return FALSE;
        auto* self = static_cast<WindowChannel*>(data);
        g_autoptr(FlValue) state = fl_value_new_map();
        fl_value_set_string_take(state, "fullscreen", fl_value_new_bool((event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0));
        fl_value_set_string_take(state, "maximized", fl_value_new_bool((event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0));
        self->Invoke("windowStateChanged", state);
        return FALSE;
      }), this);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ = fl_method_channel_new(messenger_, "tech.soit.flutterairplay/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel_,
      [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
        static_cast<WindowChannel*>(data)->Handle(call);
      }, this, nullptr);
  // A broken Dart/tray initialization must never leave an unreachable process.
  startup_timeout_ = g_timeout_add_seconds(10, [](gpointer data) -> gboolean {
    auto* self = static_cast<WindowChannel*>(data);
    self->startup_timeout_ = 0;
    self->FinishDesktopStartup(false);
    return G_SOURCE_REMOVE;
  }, this);
}

WindowChannel::~WindowChannel() {
  if (startup_timeout_) g_source_remove(startup_timeout_);
  if (g_signal_handler_is_connected(window_, state_handler_))
    g_signal_handler_disconnect(window_, state_handler_);
  fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
  fl_binary_messenger_set_message_handler_on_channel(messenger_, "tech.soit.flutterairplay/window", nullptr, nullptr, nullptr);
  g_object_unref(channel_); g_object_unref(messenger_); g_object_unref(window_);
}

void WindowChannel::Invoke(const char* method, FlValue* args) {
  fl_method_channel_invoke_method(channel_, method, args, nullptr, nullptr, nullptr);
}
void WindowChannel::Show() {
  if (!startup_finished_) reopen_requested_ = true;
  // Native presentation must work even if Dart failed after desktopReady.
  gtk_window_present(window_);
  if (startup_finished_ && ready_) Invoke("openApp");
}
bool WindowChannel::FinishDesktopStartup(bool tray_available) {
  tray_available = tray_available && tray_host_available_();
  if (startup_finished_ && tray_available) return true;
  startup_finished_ = true;
  if (startup_timeout_) { g_source_remove(startup_timeout_); startup_timeout_ = 0; }
  if (!tray_available || reopen_requested_) {
    if (!tray_available) hide_on_close_ = false;
    gtk_window_present(window_);
    if (ready_) Invoke("openApp");
  }
  return tray_available;
}
bool WindowChannel::HideOnClose() {
  if (quit_requested_ || !hide_on_close_) return false;
  Invoke("closeRequested");
  return true;
}
void WindowChannel::Handle(FlMethodCall* call) {
  const char* method = fl_method_call_get_name(call);
  auto* args = fl_method_call_get_args(call);
  if (!std::strcmp(method, "getNativeWindowHandle")) {
    g_autoptr(FlValue) handle = fl_value_new_int(static_cast<int64_t>(reinterpret_cast<intptr_t>(window_)));
    fl_method_call_respond_success(call, handle, nullptr); return;
  } else if (!std::strcmp(method, "desktopReady")) {
    ready_ = true;
    g_autoptr(FlValue) ready = fl_value_new_bool(true);
    fl_method_call_respond_success(call, ready, nullptr); return;
  } else if (!std::strcmp(method, "finishDesktopStartup")) {
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_BOOL) {
      fl_method_call_respond_error(call, "invalid_arguments", "finishDesktopStartup requires a boolean", nullptr, nullptr);
      return;
    }
    g_autoptr(FlValue) available = fl_value_new_bool(FinishDesktopStartup(fl_value_get_bool(args)));
    fl_method_call_respond_success(call, available, nullptr); return;
  } else if (!std::strcmp(method, "setClosePolicy")) {
    hide_on_close_ = args && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(args);
  } else if (!std::strcmp(method, "setDockVisible")) {
    // Dock visibility is managed by the desktop shell on Linux.
  } else if (!std::strcmp(method, "closeWindow") || !std::strcmp(method, "quitApp")) {
    quit_requested_ = !std::strcmp(method, "quitApp");
    fl_method_call_respond_success(call, nullptr, nullptr);
    g_idle_add_full(G_PRIORITY_DEFAULT, [](gpointer data) -> gboolean {
      gtk_window_close(GTK_WINDOW(data)); return G_SOURCE_REMOVE;
    }, g_object_ref(window_), g_object_unref);
    return;
  } else {
    fl_method_call_respond_not_implemented(call, nullptr); return;
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}

void AddWindowResizeHandles(GtkOverlay* overlay, GtkWindow* window) {
  struct Grip { GdkWindowEdge edge; GtkAlign horizontal, vertical; const char* cursor; };
  const Grip grips[] = {
    {GDK_WINDOW_EDGE_NORTH_WEST, GTK_ALIGN_START, GTK_ALIGN_START, "nw-resize"},
    {GDK_WINDOW_EDGE_NORTH, GTK_ALIGN_FILL, GTK_ALIGN_START, "n-resize"},
    {GDK_WINDOW_EDGE_NORTH_EAST, GTK_ALIGN_END, GTK_ALIGN_START, "ne-resize"},
    {GDK_WINDOW_EDGE_WEST, GTK_ALIGN_START, GTK_ALIGN_FILL, "w-resize"},
    {GDK_WINDOW_EDGE_EAST, GTK_ALIGN_END, GTK_ALIGN_FILL, "e-resize"},
    {GDK_WINDOW_EDGE_SOUTH_WEST, GTK_ALIGN_START, GTK_ALIGN_END, "sw-resize"},
    {GDK_WINDOW_EDGE_SOUTH, GTK_ALIGN_FILL, GTK_ALIGN_END, "s-resize"},
    {GDK_WINDOW_EDGE_SOUTH_EAST, GTK_ALIGN_END, GTK_ALIGN_END, "se-resize"},
  };
  for (const auto& grip : grips) {
    auto* box = gtk_event_box_new();
    gtk_widget_set_halign(box, grip.horizontal); gtk_widget_set_valign(box, grip.vertical);
    gtk_widget_set_size_request(box, 6, 6);
    if (grip.horizontal == GTK_ALIGN_FILL) {
      gtk_widget_set_margin_start(box, 6); gtk_widget_set_margin_end(box, 6);
    }
    if (grip.vertical == GTK_ALIGN_FILL) {
      gtk_widget_set_margin_top(box, 6); gtk_widget_set_margin_bottom(box, 6);
    }
    g_object_set_data(G_OBJECT(box), "resize-edge", GINT_TO_POINTER(grip.edge));
    g_signal_connect(box, "button-press-event", G_CALLBACK(+[](GtkWidget* widget, GdkEventButton* event, gpointer data) -> gboolean {
      if (event->button != GDK_BUTTON_PRIMARY) return FALSE;
      auto edge = static_cast<GdkWindowEdge>(GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "resize-edge")));
      gtk_window_begin_resize_drag(GTK_WINDOW(data), edge, event->button, event->x_root, event->y_root, event->time);
      return TRUE;
    }), window);
    g_signal_connect(box, "realize", G_CALLBACK(+[](GtkWidget* widget, gpointer data) {
      g_autoptr(GdkCursor) cursor = gdk_cursor_new_from_name(gtk_widget_get_display(widget), static_cast<const char*>(data));
      gdk_window_set_cursor(gtk_widget_get_window(widget), cursor);
    }), const_cast<char*>(grip.cursor));
    g_signal_connect_object(window, "window-state-event", G_CALLBACK(+[](GtkWidget*, GdkEventWindowState* event, gpointer data) -> gboolean {
      gtk_widget_set_visible(GTK_WIDGET(data), !(event->new_window_state & (GDK_WINDOW_STATE_FULLSCREEN | GDK_WINDOW_STATE_MAXIMIZED)));
      return FALSE;
    }), box, static_cast<GConnectFlags>(0));
    gtk_overlay_add_overlay(overlay, box);
    gtk_widget_show(box);
  }
}
