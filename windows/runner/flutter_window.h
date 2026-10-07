#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
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
  bool hide_on_close_ = false, quit_requested_ = false, desktop_ready_ = false;

  void UpdateSnapshot(const flutter::EncodableMap& snapshot);
  bool startup_finished_ = false, reopen_requested_ = false;
  UINT_PTR startup_timer_ = 0;
  bool FinishDesktopStartup(bool tray_available);
  void ShowApp();
  void CloseAppWindow();
  void FullscreenChanged();
  void Invoke(const char* method);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
