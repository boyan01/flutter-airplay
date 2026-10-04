// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <libayatana-appindicator/app-indicator.h>
#include <map>
#include <string>

// GTK executes desktop window commands; Flutter retains the shared UI.
class WindowChannel {
 public:
  WindowChannel(FlBinaryMessenger* messenger, GtkWindow* window, bool enable_tray = true);
  ~WindowChannel();
  WindowChannel(const WindowChannel&) = delete;
  WindowChannel& operator=(const WindowChannel&) = delete;
  void UpdateSnapshot(FlValue* snapshot);
  void Show(bool user_initiated = true);
  bool HideOnClose();
 private:
  void Handle(FlMethodCall* call);
  void Invoke(const char* method, FlValue* args = nullptr);
  void SetFullscreen(bool target);
  void ApplyMode(bool preserve_area = false, bool actual_size = false);
  void UpdateTray();
  void CancelAutoHide();
  void AddItem(const std::string& label, const char* method, bool enabled = true,
               bool checked = false);
  std::string Text(const char* key) const;
  bool Preference(const char* key, bool fallback = false) const;
  FlBinaryMessenger* messenger_;
  FlMethodChannel* channel_;
  GtkWindow* window_;
  gulong state_handler_ = 0;
  bool fullscreen_ = false;
  bool maximized_ = false, quit_requested_ = false;
  bool was_playing_ = false, opened_for_session_ = false;
  int width_ = 0, height_ = 0;
  guint auto_hide_ = 0;
  FlValue* snapshot_ = nullptr;
  AppIndicator* indicator_ = nullptr;
  GtkWidget* menu_ = nullptr;
  std::string icon_directory_;
  std::map<std::string, std::string> strings_;

};

void AddWindowResizeHandles(GtkOverlay* overlay, GtkWindow* window);
