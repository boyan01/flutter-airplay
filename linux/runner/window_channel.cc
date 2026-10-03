// SPDX-License-Identifier: GPL-3.0-only
#include "window_channel.h"
#include <cstring>

WindowChannel::WindowChannel(FlBinaryMessenger* messenger, GtkWindow* window)
    : messenger_(FL_BINARY_MESSENGER(g_object_ref(messenger))),
      window_(GTK_WINDOW(g_object_ref(window))) {
  state_handler_ = g_signal_connect(window_, "window-state-event",
      G_CALLBACK(+[](GtkWidget*, GdkEventWindowState* event, gpointer data) -> gboolean {
        if (event->changed_mask & GDK_WINDOW_STATE_FULLSCREEN)
          static_cast<WindowChannel*>(data)->fullscreen_ =
              (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0;
        return FALSE;
      }), this);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ = fl_method_channel_new(messenger_, "org.flutterairplay/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel_,
      [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
        static_cast<WindowChannel*>(data)->Handle(call);
      }, this, nullptr);
}
WindowChannel::~WindowChannel() {
  g_signal_handler_disconnect(window_, state_handler_);
  fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
  fl_binary_messenger_set_message_handler_on_channel(messenger_, "org.flutterairplay/window",
                                                       nullptr, nullptr, nullptr);
  g_object_unref(channel_);
  g_object_unref(messenger_);
  g_object_unref(window_);
}
void WindowChannel::Handle(FlMethodCall* call) {
  const char* method = fl_method_call_get_name(call);
  if (!std::strcmp(method, "setMode")) {
    // Preserve the user's desktop geometry. The shared player letterboxes the
    // texture and uses decoded dimensions, including portrait rotation.
  } else if (!std::strcmp(method, "minimizeWindow")) {
    gtk_window_iconify(window_);
  } else if (!std::strcmp(method, "closeWindow")) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    // Finish the method reply before shutdown unregisters its channel.
    g_idle_add_full(G_PRIORITY_DEFAULT, [](gpointer window) -> gboolean {
      gtk_window_close(GTK_WINDOW(window)); return G_SOURCE_REMOVE;
    }, g_object_ref(window_), g_object_unref);
    return;
  } else if (!std::strcmp(method, "toggleFullscreen") || !std::strcmp(method, "exitFullscreen") ||
             !std::strcmp(method, "setFullscreen")) {
    bool target = !std::strcmp(method, "toggleFullscreen") ? !fullscreen_ : false;
    if (!std::strcmp(method, "setFullscreen")) {
      auto* args = fl_method_call_get_args(call);
      auto* value = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
          ? fl_value_lookup_string(args, "fullscreen") : nullptr;
      if (!value || fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
        fl_method_call_respond_error(call, "window_error", "Missing fullscreen boolean", nullptr, nullptr);
        return;
      }
      target = fl_value_get_bool(value);
    }
    fullscreen_ = target;
    if (target) gtk_window_fullscreen(window_); else gtk_window_unfullscreen(window_);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr); return;
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}
