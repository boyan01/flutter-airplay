// SPDX-License-Identifier: GPL-3.0-only
#include "window_channel.h"
#include <cstring>
#include <cstdint>
#include <utility>
#include <string>
#include <unistd.h>

namespace {
bool TrayRegistered(GCancellable* cancellable) {
  // nativeapi 0.4 reports visibility even when registration fails. Require a
  // host and this process's item; nativeapi uses a private D-Bus connection.
  g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SESSION, cancellable, nullptr);
  if (!bus) return false;
  for (const char* watcher : {"org.kde.StatusNotifierWatcher", "com.canonical.StatusNotifierWatcher"}) {
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(bus,
        watcher, "/StatusNotifierWatcher", "org.freedesktop.DBus.Properties", "GetAll",
        g_variant_new("(s)", watcher), G_VARIANT_TYPE("(a{sv})"),
        G_DBUS_CALL_FLAGS_NO_AUTO_START, 500, cancellable, nullptr);
    if (!reply) continue;
    g_autoptr(GVariant) properties = g_variant_get_child_value(reply, 0);
    gboolean host = FALSE;
    if (!g_variant_lookup(properties, "IsStatusNotifierHostRegistered", "b", &host) || !host) continue;
    g_autoptr(GVariant) items = g_variant_lookup_value(properties, "RegisteredStatusNotifierItems", G_VARIANT_TYPE("as"));
    if (!items) continue;
    GVariantIter iterator;
    g_variant_iter_init(&iterator, items);
    const gchar* item;
    while (g_variant_iter_next(&iterator, "&s", &item)) {
      if (g_cancellable_is_cancelled(cancellable)) return false;
      const char* path = std::strchr(item, '/');
      if (!path || std::strcmp(path, "/StatusNotifierItem")) continue;
      const std::string service(item, path - item);
      if (!g_dbus_is_name(service.c_str())) continue;
      g_autoptr(GVariant) owner = g_dbus_connection_call_sync(bus,
          "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
          "GetConnectionUnixProcessID", g_variant_new("(s)", service.c_str()),
          G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 500, cancellable, nullptr);
      guint32 pid = 0;
      if (owner) g_variant_get(owner, "(u)", &pid);
      if (pid == static_cast<guint32>(getpid())) return true;
    }
  }
  return false;
}
}  // namespace

WindowChannel::WindowChannel(FlBinaryMessenger* messenger, GtkWindow* window,
                             std::function<bool()> tray_registered)
    : messenger_(FL_BINARY_MESSENGER(g_object_ref(messenger))),
      window_(GTK_WINDOW(g_object_ref(window))),
      tray_registered_(std::move(tray_registered)) {
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
  CancelTrayProbe();
  if (startup_call_) {
    fl_method_call_respond_error(startup_call_, "window_closed", "Window closed during tray startup", nullptr, nullptr);
    g_clear_object(&startup_call_);
  }
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
void WindowChannel::CancelTrayProbe() {
  if (tray_timeout_) { g_source_remove(tray_timeout_); tray_timeout_ = 0; }
  if (tray_retry_) { g_source_remove(tray_retry_); tray_retry_ = 0; }
  if (tray_probe_) {
    g_cancellable_cancel(tray_probe_);
    g_clear_object(&tray_probe_);
  }
}

void WindowChannel::ProbeTrayRegistration() {
  tray_probe_ = g_cancellable_new();
  // D-Bus round trips run off GTK's thread. The nativeapi registration callback
  // remains free to run while this method-channel response waits for the item.
  g_autoptr(GTask) task = g_task_new(nullptr, tray_probe_,
      [](GObject*, GAsyncResult* result, gpointer data) {
        auto* task = G_TASK(result);
        // Destruction/watchdog cancellation may leave a queued callback. Check
        // its owned cancellable before ever dereferencing the window channel.
        if (g_cancellable_is_cancelled(g_task_get_cancellable(task))) return;
        auto* self = static_cast<WindowChannel*>(data);
        g_clear_object(&self->tray_probe_);
        const bool registered = g_task_propagate_boolean(task, nullptr);
        if (registered) {
          self->FinishDesktopStartup(registered);
        } else {
          self->tray_retry_ = g_timeout_add(100, [](gpointer data) -> gboolean {
            auto* self = static_cast<WindowChannel*>(data);
            self->tray_retry_ = 0;
            self->ProbeTrayRegistration();
            return G_SOURCE_REMOVE;
          }, self);
        }
      }, this);
  auto* probe = new std::function<bool()>(tray_registered_);
  g_task_set_task_data(task, probe, [](gpointer data) { delete static_cast<std::function<bool()>*>(data); });
  g_task_run_in_thread(task, [](GTask* task, gpointer, gpointer data, GCancellable* cancellable) {
    const auto& probe = *static_cast<std::function<bool()>*>(data);
    g_task_return_boolean(task, probe ? probe() : TrayRegistered(cancellable));
  });
}

bool WindowChannel::FinishDesktopStartup(bool tray_available) {
  CancelTrayProbe();
  const bool already_finished = startup_finished_;
  startup_finished_ = true;
  if (startup_timeout_) { g_source_remove(startup_timeout_); startup_timeout_ = 0; }
  if (!tray_available || (!already_finished && reopen_requested_)) {
    if (!tray_available) hide_on_close_ = false;
    gtk_window_present(window_);
    if (ready_) Invoke("openApp");
  }
  if (startup_call_) {
    g_autoptr(FlValue) available = fl_value_new_bool(tray_available);
    fl_method_call_respond_success(startup_call_, available, nullptr);
    g_clear_object(&startup_call_);
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
    if (!fl_value_get_bool(args)) {
      g_autoptr(FlValue) available = fl_value_new_bool(FinishDesktopStartup(false));
      fl_method_call_respond_success(call, available, nullptr);
    } else if (startup_call_) {
      fl_method_call_respond_error(call, "startup_in_progress", "Tray startup is already pending", nullptr, nullptr);
    } else {
      startup_call_ = FL_METHOD_CALL(g_object_ref(call));
      tray_timeout_ = g_timeout_add(3000, [](gpointer data) -> gboolean {
        auto* self = static_cast<WindowChannel*>(data);
        self->tray_timeout_ = 0;
        self->FinishDesktopStartup(false);
        return G_SOURCE_REMOVE;
      }, this);
      ProbeTrayRegistration();
    }
    return;
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
