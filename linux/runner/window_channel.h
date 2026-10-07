// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <functional>

// The host only bridges OS close/reopen and completed window state changes.
class WindowChannel {
 public:
  WindowChannel(FlBinaryMessenger* messenger, GtkWindow* window,
                std::function<bool()> tray_host_available = {});
  ~WindowChannel();
  WindowChannel(const WindowChannel&) = delete;
  WindowChannel& operator=(const WindowChannel&) = delete;
  void Show();
  bool HideOnClose();
  bool FinishDesktopStartup(bool tray_available);
 private:
  void Handle(FlMethodCall* call);
  void Invoke(const char* method, FlValue* args = nullptr);
  FlBinaryMessenger* messenger_;
  FlMethodChannel* channel_;
  GtkWindow* window_;
  gulong state_handler_ = 0;
  guint startup_timeout_ = 0;
  std::function<bool()> tray_host_available_;
  bool startup_finished_ = false, reopen_requested_ = false;
  bool hide_on_close_ = false, quit_requested_ = false, ready_ = false;
};

void AddWindowResizeHandles(GtkOverlay* overlay, GtkWindow* window);
