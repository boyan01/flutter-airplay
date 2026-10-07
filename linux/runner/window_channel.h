// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <functional>

// The host only bridges OS close/reopen and completed window state changes.
class WindowChannel {
 public:
  WindowChannel(FlBinaryMessenger* messenger, GtkWindow* window,
                bool launch_at_login = false,
                std::function<bool()> tray_registered = {});
  ~WindowChannel();
  WindowChannel(const WindowChannel&) = delete;
  WindowChannel& operator=(const WindowChannel&) = delete;
  void Show();
  bool HideOnClose();
  bool FinishDesktopStartup(bool tray_available);
 private:
  void Handle(FlMethodCall* call);
  void ProbeTrayRegistration();
  void CancelTrayProbe();
  void Invoke(const char* method, FlValue* args = nullptr);
  FlBinaryMessenger* messenger_;
  FlMethodChannel* channel_;
  GtkWindow* window_;
  gulong state_handler_ = 0;
  guint startup_timeout_ = 0, tray_retry_ = 0, tray_timeout_ = 0;
  GCancellable* tray_probe_ = nullptr;
  FlMethodCall* startup_call_ = nullptr;
  std::function<bool()> tray_registered_;
  const bool launch_at_login_;
  bool startup_finished_ = false, reopen_requested_ = false;
  bool hide_on_close_ = false, quit_requested_ = false, ready_ = false;
};

void AddWindowResizeHandles(GtkOverlay* overlay, GtkWindow* window);
