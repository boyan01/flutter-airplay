#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <map>
#include <string>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include "win32_window.h"
#include "receiver_bridge.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();
  static constexpr UINT kShowWindowMessage = WM_APP + 74;

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<ReceiverBridge> receiver_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> presentation_;
  flutter::EncodableMap snapshot_;
  std::map<std::string, std::wstring> strings_;
  HICON tray_icon_ = nullptr;
  bool tray_added_ = false, was_playing_ = false, opened_for_session_ = false;
  bool quit_requested_ = false;
  DWORD tray_color_ = 0;
  UINT taskbar_created_ = 0;

  void UpdateSnapshot(const flutter::EncodableMap& snapshot);
  void UpdateTray();
  void TrayMenu(POINT point);
  void ShowApp(bool user_initiated = true);
  void HideApp(bool disconnect);
  void CloseAppWindow();
  void WindowStateChanged();
  void Invoke(const char* method);
  std::wstring Text(const char* key) const;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
