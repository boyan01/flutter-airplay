// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The host only bridges OS close/reopen and completed window state changes.
class WindowChannel {
 public:
  WindowChannel(FlBinaryMessenger* messenger, GtkWindow* window);
  ~WindowChannel();
  WindowChannel(const WindowChannel&) = delete;
  WindowChannel& operator=(const WindowChannel&) = delete;
  void Show();
  bool HideOnClose();
 private:
  void Handle(FlMethodCall* call);
  void Invoke(const char* method, FlValue* args = nullptr);
  FlBinaryMessenger* messenger_;
  FlMethodChannel* channel_;
  GtkWindow* window_;
  gulong state_handler_ = 0;
  bool hide_on_close_ = false, quit_requested_ = false, ready_ = false;
};

void AddWindowResizeHandles(GtkOverlay* overlay, GtkWindow* window);
