// SPDX-License-Identifier: GPL-3.0-only
#include "window_channel.h"
#include <algorithm>
#include <cmath>
#include <cstring>

namespace {
FlValue* Lookup(FlValue* map, const char* key) {
  return map && fl_value_get_type(map) == FL_VALUE_TYPE_MAP
      ? fl_value_lookup_string(map, key) : nullptr;
}
std::string String(FlValue* map, const char* key) {
  auto* value = Lookup(map, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : "";
}
int Integer(FlValue* map, const char* key) {
  auto* value = Lookup(map, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_INT ? fl_value_get_int(value) : 0;
}
bool Active(const std::string& state) {
  return state == "checking" || state == "starting" || state == "waiting" ||
         state == "streaming" || state == "stopping";
}
bool Transitioning(const std::string& state) {
  return state == "checking" || state == "starting" || state == "stopping";
}
void CloseLater(GtkWindow* window) {
  g_idle_add_full(G_PRIORITY_DEFAULT, [](gpointer data) -> gboolean {
    gtk_window_close(GTK_WINDOW(data)); return G_SOURCE_REMOVE;
  }, g_object_ref(window), g_object_unref);
}
}  // namespace

WindowChannel::WindowChannel(FlBinaryMessenger* messenger, GtkWindow* window, bool enable_tray)
    : messenger_(FL_BINARY_MESSENGER(g_object_ref(messenger))),
      window_(GTK_WINDOW(g_object_ref(window))) {
  state_handler_ = g_signal_connect(window_, "window-state-event",
      G_CALLBACK(+[](GtkWidget*, GdkEventWindowState* event, gpointer data) -> gboolean {
        auto* self = static_cast<WindowChannel*>(data);
        const bool constrained = self->fullscreen_ || self->maximized_;
        self->fullscreen_ = (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0;
        self->maximized_ = (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0;
        if (constrained && !self->fullscreen_ && !self->maximized_) self->ApplyMode(true);
        g_autoptr(FlValue) state = fl_value_new_map();
        fl_value_set_string_take(state, "fullscreen", fl_value_new_bool(self->fullscreen_));
        fl_value_set_string_take(state, "maximized", fl_value_new_bool(self->maximized_));
        self->Invoke("windowStateChanged", state);
        self->UpdateTray();
        return FALSE;
      }), this);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ = fl_method_channel_new(messenger_, "tech.soit.flutterairplay/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel_,
      [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
        static_cast<WindowChannel*>(data)->Handle(call);
      }, this, nullptr);
  if (enable_tray) {
    g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
    g_autofree gchar* directory = executable ? g_path_get_dirname(executable) : nullptr;
    g_autofree gchar* icons = directory ? g_build_filename(directory, "data", "icons", nullptr) : nullptr;
    g_autofree gchar* icon = icons ? g_build_filename(icons, "airplay-idle.svg", nullptr) : nullptr;
    if (icon && g_file_test(icon, G_FILE_TEST_IS_REGULAR)) {
      icon_directory_ = icons;
      indicator_ = app_indicator_new_with_path("flutter-airplay", "airplay-idle",
          APP_INDICATOR_CATEGORY_APPLICATION_STATUS, icons);
      g_signal_connect(indicator_, "connection-changed",
          G_CALLBACK(+[](AppIndicator*, gboolean connected, gpointer data) {
            auto* self = static_cast<WindowChannel*>(data);
            if (!connected && !gtk_widget_get_visible(GTK_WIDGET(self->window_))) self->Show();
          }), this);
      UpdateTray();
      app_indicator_set_status(indicator_, APP_INDICATOR_STATUS_ACTIVE);
    }
  }
}

WindowChannel::~WindowChannel() {
  CancelAutoHide();
  if (snapshot_) fl_value_unref(snapshot_);
  if (indicator_) {
    g_signal_handlers_disconnect_by_data(indicator_, this);
    app_indicator_set_secondary_activate_target(indicator_, nullptr);
    app_indicator_set_status(indicator_, APP_INDICATOR_STATUS_PASSIVE);
    g_object_unref(indicator_);
  }
  if (menu_) { gtk_widget_destroy(menu_); g_object_unref(menu_); }
  if (g_signal_handler_is_connected(window_, state_handler_))
    g_signal_handler_disconnect(window_, state_handler_);
  fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
  fl_binary_messenger_set_message_handler_on_channel(messenger_, "tech.soit.flutterairplay/window",
                                                       nullptr, nullptr, nullptr);
  g_object_unref(channel_);
  g_object_unref(messenger_);
  g_object_unref(window_);
}

void WindowChannel::Invoke(const char* method, FlValue* args) {
  fl_method_channel_invoke_method(channel_, method, args, nullptr, nullptr, nullptr);
}
bool WindowChannel::Preference(const char* key, bool fallback) const {
  auto* value = Lookup(snapshot_, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL ? fl_value_get_bool(value) : fallback;
}
std::string WindowChannel::Text(const char* key) const {
  const auto item = strings_.find(key);
  return item != strings_.end() ? item->second : key;
}
void WindowChannel::CancelAutoHide() {
  if (auto_hide_) g_source_remove(auto_hide_);
  auto_hide_ = 0;
}
void WindowChannel::Show(bool user_initiated) {
  if (user_initiated) { CancelAutoHide(); opened_for_session_ = false; }
  gtk_window_deiconify(window_);
  gtk_window_present(window_);
}
bool WindowChannel::HideOnClose() {
  gboolean connected = FALSE;
  if (indicator_) g_object_get(indicator_, "connected", &connected, nullptr);
  if (quit_requested_ || !connected || !Preference("keepInMenuBar", true)) return false;
  CancelAutoHide();
  opened_for_session_ = false;
  if (String(snapshot_, "status") == "streaming") Invoke("disconnectSession");
  gtk_widget_hide(GTK_WIDGET(window_));
  return true;
}
void WindowChannel::SetFullscreen(bool target) {
  if (target) gtk_window_fullscreen(window_); else gtk_window_unfullscreen(window_);
}
void WindowChannel::ApplyMode(bool preserve_area, bool actual_size) {
  if (fullscreen_ || maximized_) return;
  GdkRectangle work{0, 0, 1280, 800};
  auto* surface = gtk_widget_get_window(GTK_WIDGET(window_));
  auto* display = gtk_widget_get_display(GTK_WIDGET(window_));
  auto* monitor = surface ? gdk_display_get_monitor_at_window(display, surface)
                          : gdk_display_get_primary_monitor(display);
  if (monitor) gdk_monitor_get_workarea(monitor, &work);
  int old_width, old_height, x, y;
  gtk_window_get_size(window_, &old_width, &old_height);
  gtk_window_get_position(window_, &x, &y);
  int width = 440, height = 560;
  GdkGeometry geometry{};
  geometry.min_width = 360; geometry.min_height = 480;
  GdkWindowHints hints = GDK_HINT_MIN_SIZE;
  if (width_ > 0 && height_ > 0) {
    const double ratio = double(width_) / height_;
    const double max_width = work.width * .8, max_height = work.height * .8;
    const double target = actual_size ? width_ : preserve_area
        ? std::sqrt(double(old_width) * old_height * ratio) : max_width;
    width = std::max(1, int(std::min(target, std::min(max_width, max_height * ratio))));
    height = std::max(1, int(width / ratio));
    geometry.min_width = 160; geometry.min_height = 160;
    geometry.min_aspect = geometry.max_aspect = ratio;
    hints = static_cast<GdkWindowHints>(hints | GDK_HINT_ASPECT);
  }
  gtk_window_set_geometry_hints(window_, nullptr, &geometry, hints);
  gtk_window_resize(window_, width, height);
  // Wayland decides placement; X11 preserves the center on rotation.
  gtk_window_move(window_, std::max(work.x, std::min(x + (old_width - width) / 2, work.x + work.width - width)),
      std::max(work.y, std::min(y + (old_height - height) / 2, work.y + work.height - height)));
}
void WindowChannel::UpdateSnapshot(FlValue* snapshot) {
  fl_value_ref(snapshot);
  if (snapshot_) fl_value_unref(snapshot_);
  snapshot_ = snapshot;
  const bool playing = Integer(snapshot_, "videoWidth") > 0 && Integer(snapshot_, "videoHeight") > 0;
  if (playing && !was_playing_) {
    CancelAutoHide();
    auto* surface = gtk_widget_get_window(GTK_WIDGET(window_));
    const bool minimized = surface && (gdk_window_get_state(surface) & GDK_WINDOW_STATE_ICONIFIED);
    if ((!gtk_widget_get_visible(GTK_WIDGET(window_)) || minimized) && Preference("showOnConnect", true)) {
      opened_for_session_ = true; Show(false);
    }
    if (Preference("fullscreenOnConnect")) SetFullscreen(true);
  } else if (!playing && was_playing_ && opened_for_session_) {
    CancelAutoHide();
    auto_hide_ = g_timeout_add(3000, [](gpointer data) -> gboolean {
      auto* self = static_cast<WindowChannel*>(data);
      self->auto_hide_ = 0;
      gboolean connected = FALSE;
      if (self->indicator_) g_object_get(self->indicator_, "connected", &connected, nullptr);
      if (!self->was_playing_ && self->opened_for_session_ && connected && self->Preference("keepInMenuBar", true)) {
        gtk_widget_hide(GTK_WIDGET(self->window_)); self->opened_for_session_ = false;
      }
      return G_SOURCE_REMOVE;
    }, this);
  }
  gtk_window_set_keep_above(window_, playing && Preference("alwaysOnTop"));
  was_playing_ = playing;
  UpdateTray();
}
void WindowChannel::AddItem(const std::string& label, const char* method, bool enabled, bool checked) {
  auto* item = std::strcmp(method, "toggleReceiver") && std::strcmp(method, "toggleOnTop")
      ? gtk_menu_item_new_with_label(label.c_str()) : gtk_check_menu_item_new_with_label(label.c_str());
  if (GTK_IS_CHECK_MENU_ITEM(item)) gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item), checked);
  gtk_widget_set_sensitive(item, enabled);
  if (*method) {
    g_object_set_data_full(G_OBJECT(item), "window-command", g_strdup(method), g_free);
    g_signal_connect(item, "activate", G_CALLBACK(+[](GtkWidget* item, gpointer data) {
      auto* self = static_cast<WindowChannel*>(data);
      auto* command = static_cast<const char*>(g_object_get_data(G_OBJECT(item), "window-command"));
      if (!std::strcmp(command, "openApp")) self->Show();
      else if (!std::strcmp(command, "quitApp")) { self->quit_requested_ = true; CloseLater(self->window_); }
      else if (!std::strcmp(command, "toggleFullscreen")) self->SetFullscreen(!self->fullscreen_);
      else if (!std::strcmp(command, "actualSize")) self->ApplyMode(false, true);
      else if (!std::strcmp(command, "fitScreen")) self->ApplyMode();
      else {
        if (!std::strcmp(command, "openSettings") || !std::strcmp(command, "openLogs")) self->Show();
        self->Invoke(command);
      }
    }), this);
  }
  gtk_menu_shell_append(GTK_MENU_SHELL(menu_), item);
}
void WindowChannel::UpdateTray() {
  if (!indicator_) return;
  auto* previous = menu_;
  menu_ = gtk_menu_new();
  g_object_ref_sink(menu_);
  const auto status = String(snapshot_, "status");
  const bool playing = Integer(snapshot_, "videoWidth") > 0 && Integer(snapshot_, "videoHeight") > 0;
  auto name = String(snapshot_, "name");
  if (name.empty()) name = "Flutter AirPlay";
  const auto label = status == "error" ? Text("unavailable") : playing ? Text("playing")
      : Preference("audioPlaying") ? Text("audioPlaying") : Transitioning(status) ? Text("starting")
      : Active(status) ? Text("discoverable") : Text("off");
  AddItem(name, "", false);
  AddItem(status == "error" ? String(snapshot_, "message") : label, "", false);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu_), gtk_separator_menu_item_new());
  AddItem(Text(playing ? "showPlayer" : "openApp"), "openApp");
  AddItem(Text("receive"), "toggleReceiver", !Transitioning(status), Active(status));
  if (status == "streaming") AddItem(Text("disconnect"), "disconnectSession");
  if (playing) {
    AddItem(Text(fullscreen_ ? "exitFullscreen" : "enterFullscreen"), "toggleFullscreen");
    AddItem(Text("actualSize"), "actualSize", !fullscreen_ && !maximized_);
    AddItem(Text("fitScreen"), "fitScreen", !fullscreen_ && !maximized_);
    AddItem(Text("alwaysOnTop"), "toggleOnTop", true, Preference("alwaysOnTop"));
  }
  gtk_menu_shell_append(GTK_MENU_SHELL(menu_), gtk_separator_menu_item_new());
  AddItem(Text("settings"), "openSettings"); AddItem(Text("logs"), "openLogs");
  gtk_menu_shell_append(GTK_MENU_SHELL(menu_), gtk_separator_menu_item_new());
  AddItem(Text("quitApp"), "quitApp");
  gtk_widget_show_all(menu_);
  app_indicator_set_secondary_activate_target(indicator_, nullptr);
  app_indicator_set_menu(indicator_, GTK_MENU(menu_));
  auto* children = gtk_container_get_children(GTK_CONTAINER(menu_));
  app_indicator_set_secondary_activate_target(indicator_, GTK_WIDGET(g_list_nth_data(children, 3)));
  g_list_free(children);
  const auto icon = icon_directory_ + (status == "error" ? "/airplay-error.svg" : playing || Preference("audioPlaying")
      ? "/airplay-playing.svg" : "/airplay-idle.svg");
  app_indicator_set_icon_full(indicator_, icon.c_str(), label.c_str());
  app_indicator_set_title(indicator_, name.c_str());
  if (previous) { gtk_widget_destroy(previous); g_object_unref(previous); }
}
void WindowChannel::Handle(FlMethodCall* call) {
  const char* method = fl_method_call_get_name(call);
  auto* args = fl_method_call_get_args(call);
  if (!std::strcmp(method, "setMode")) {
    const bool was_playing = width_ > 0 && height_ > 0;
    width_ = String(args, "mode") == "player" ? Integer(args, "width") : 0;
    height_ = String(args, "mode") == "player" ? Integer(args, "height") : 0;
    ApplyMode(was_playing);
  } else if (!std::strcmp(method, "setStrings")) {
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      for (size_t i = 0; i < fl_value_get_length(args); ++i) {
        auto* key = fl_value_get_map_key(args, i); auto* value = fl_value_get_map_value(args, i);
        if (fl_value_get_type(key) == FL_VALUE_TYPE_STRING && fl_value_get_type(value) == FL_VALUE_TYPE_STRING)
          strings_[fl_value_get_string(key)] = fl_value_get_string(value);
      }
    }
    UpdateTray();
  } else if (!std::strcmp(method, "toggleMaximize")) {
    if (fullscreen_) SetFullscreen(false);
    else if (maximized_) gtk_window_unmaximize(window_);
    else gtk_window_maximize(window_);
  } else if (!std::strcmp(method, "minimizeWindow")) {
    gtk_window_iconify(window_);
  } else if (!std::strcmp(method, "closeWindow") || !std::strcmp(method, "quitApp")) {
    quit_requested_ = !std::strcmp(method, "quitApp");
    fl_method_call_respond_success(call, nullptr, nullptr);
    CloseLater(window_); return;
  } else if (!std::strcmp(method, "toggleFullscreen") || !std::strcmp(method, "exitFullscreen") ||
             !std::strcmp(method, "setFullscreen")) {
    bool target = !std::strcmp(method, "toggleFullscreen") ? !fullscreen_ : false;
    if (!std::strcmp(method, "setFullscreen")) {
      auto* value = Lookup(args, "fullscreen");
      if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
        fl_method_call_respond_error(call, "window_error", "Missing fullscreen boolean", nullptr, nullptr);
        return;
      }
      target = fl_value_get_bool(value);
    }
    SetFullscreen(target);
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
