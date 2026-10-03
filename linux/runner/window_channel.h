// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// GTK executes desktop window commands; Flutter retains the shared UI.
class WindowChannel {
 public:
  WindowChannel(FlBinaryMessenger* messenger, GtkWindow* window);
  ~WindowChannel();
  WindowChannel(const WindowChannel&) = delete;
  WindowChannel& operator=(const WindowChannel&) = delete;
 private:
  void Handle(FlMethodCall* call);
  FlBinaryMessenger* messenger_;
  FlMethodChannel* channel_;
  GtkWindow* window_;
  gulong state_handler_ = 0;
  bool fullscreen_ = false;
};
