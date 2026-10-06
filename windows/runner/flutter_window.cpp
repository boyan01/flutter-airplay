#include "flutter_window.h"

#include <optional>
#include <array>
#include <cstring>
#include <system_error>
#include <flutter/standard_method_codec.h>
#include "resource.h"
#include <flutter/plugin_registrar_windows.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kFullscreenStateMessage = WM_APP + 76;

// Keep this value name aligned with the installer's startup-entry cleanup.
constexpr auto kLoginValue = L"FlutterAirPlay";
constexpr auto kLoginRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr auto kLoginApprovalKey =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run";

bool MissingRegistryValue(LSTATUS status) {
  return status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND;
}

void CheckLoginStatus(LSTATUS status, const char* operation) {
  if (status != ERROR_SUCCESS) throw std::system_error(static_cast<int>(status), std::system_category(), operation);
}

std::wstring LoginCommand() {
  std::wstring path(32768, L'\0');
  const auto length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!length) CheckLoginStatus(GetLastError(), "Cannot find the application for login startup");
  if (length >= path.size()) CheckLoginStatus(ERROR_INSUFFICIENT_BUFFER, "Login startup executable path is too long");
  path.resize(length);
  return L"\"" + path + L"\"";
}

bool LoginApproved() {
  std::array<BYTE, 12> approval{};
  DWORD size = static_cast<DWORD>(approval.size());
  const auto status = RegGetValueW(HKEY_CURRENT_USER, kLoginApprovalKey, kLoginValue,
      RRF_RT_REG_BINARY, nullptr, approval.data(), &size);
  // Windows permits Run entries with no StartupApproved record.
  if (MissingRegistryValue(status)) return true;
  CheckLoginStatus(status, "Cannot read Windows startup approval");
  if (size != approval.size()) CheckLoginStatus(ERROR_INVALID_DATA, "Invalid Windows startup approval");
  DWORD state = 0;
  std::memcpy(&state, approval.data(), sizeof(state));
  // The shell uses 2/6 for enabled and 3/7 for disabled; zero is its
  // uninitialized state. Unknown states must not claim startup is enabled.
  return state == 0 || state == 2 || state == 6;
}

bool LaunchAtLoginEnabled() {
  DWORD size = 0;
  auto status = RegGetValueW(HKEY_CURRENT_USER, kLoginRunKey, kLoginValue,
      RRF_RT_REG_SZ, nullptr, nullptr, &size);
  if (MissingRegistryValue(status)) return false;
  CheckLoginStatus(status, "Cannot read login startup registration");
  if (size > 65536 || size < sizeof(wchar_t) || size % sizeof(wchar_t) != 0) {
    CheckLoginStatus(ERROR_INVALID_DATA, "Invalid login startup command");
  }
  // Reserve a terminator even if a malformed registry value lacks one.
  std::wstring value(size / sizeof(wchar_t) + 1, L'\0');
  size = static_cast<DWORD>(value.size() * sizeof(wchar_t));
  status = RegGetValueW(HKEY_CURRENT_USER, kLoginRunKey, kLoginValue,
      RRF_RT_REG_SZ, nullptr, value.data(), &size);
  if (MissingRegistryValue(status)) return false;
  CheckLoginStatus(status, "Cannot read login startup registration");
  value.resize(value.find(L'\0'));
  return value == LoginCommand() && LoginApproved();
}

bool SetLaunchAtLogin(bool enabled) {
  // Resolve the command before making changes so a path error leaves the
  // existing registration and Task Manager approval untouched.
  const auto command = enabled ? LoginCommand() : std::wstring();
  HKEY key = nullptr;
  auto status = enabled
      ? RegCreateKeyExW(HKEY_CURRENT_USER, kLoginRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr)
      : RegOpenKeyExW(HKEY_CURRENT_USER, kLoginRunKey, 0, KEY_SET_VALUE, &key);
  if (!enabled && MissingRegistryValue(status)) return false;
  CheckLoginStatus(status, "Cannot open login startup registration");
  if (enabled) {
    status = RegSetValueExW(key, kLoginValue, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = RegDeleteValueW(key, kLoginValue);
    if (MissingRegistryValue(status)) status = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  CheckLoginStatus(status, "Cannot update login startup registration");

  if (enabled && !LoginApproved()) {
    // Only an explicit enable may clear a user's Task Manager disable. Reads,
    // receiver saves and ordinary app startup never modify this record.
    status = RegOpenKeyExW(HKEY_CURRENT_USER, kLoginApprovalKey, 0, KEY_SET_VALUE, &key);
    if (!MissingRegistryValue(status)) {
      CheckLoginStatus(status, "Cannot open Windows startup approval");
      status = RegDeleteValueW(key, kLoginValue);
      RegCloseKey(key);
      if (!MissingRegistryValue(status)) CheckLoginStatus(status, "Cannot enable Windows startup approval");
    }
  }
  return LaunchAtLoginEnabled();
}

int Integer(const Map& values, const char* key) {
  const auto found = values.find(Value(key));
  if (found == values.end()) return 0;
  if (std::holds_alternative<int32_t>(found->second)) return std::get<int32_t>(found->second);
  if (std::holds_alternative<int64_t>(found->second)) return static_cast<int>(std::get<int64_t>(found->second));
  return 0;
}
bool Playing(const Map& snapshot) { return Integer(snapshot, "videoWidth") > 0 && Integer(snapshot, "videoHeight") > 0; }
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  auto *registrar = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(
          flutter_controller_->engine()->GetRegistrarForPlugin("AirplayReceiver"));
  presentation_ = std::make_unique<flutter::MethodChannel<Value>>(registrar->messenger(),
      "tech.soit.flutterairplay/window", &flutter::StandardMethodCodec::GetInstance());
  presentation_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result) {
    const auto& method = call.method_name();
    if (method == "quitApp") { quit_requested_ = true; PostMessageW(GetHandle(), WM_CLOSE, 0, 0); }
    else if (method == "closeWindow") PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
    else if (method == "getNativeWindowHandle") {
      result->Success(Value(static_cast<int64_t>(reinterpret_cast<intptr_t>(GetHandle())))); return;
    } else if (method == "getLaunchAtLogin" || method == "setLaunchAtLogin") {
      if (method == "setLaunchAtLogin" &&
          (!call.arguments() || !std::holds_alternative<bool>(*call.arguments()))) {
        result->Error("invalid_arguments", "setLaunchAtLogin requires a boolean"); return;
      }
      try {
        const bool enabled = method == "getLaunchAtLogin" ? LaunchAtLoginEnabled()
            : SetLaunchAtLogin(std::get<bool>(*call.arguments()));
        result->Success(Value(enabled));
      } catch (const std::system_error& error) {
        result->Error("launch_at_login_error", error.what(),
            Value(Map{{Value("code"), Value(static_cast<int64_t>(error.code().value()))}}));
      }
      return;
    } else if (method == "desktopReady") {
      desktop_ready_ = true; result->Success(Value(true)); return;
    } else if (method == "setClosePolicy") {
      hide_on_close_ = call.arguments() && std::holds_alternative<bool>(*call.arguments()) && std::get<bool>(*call.arguments());
    } else if (method == "setDockVisible") {
      // Windows owns taskbar visibility independently of macOS Dock policy.
    } else { result->NotImplemented(); return; }
    result->Success();
  });
  IDXGIAdapter *adapter = nullptr;
  flutter_controller_->engine()->GetGraphicsAdapter(&adapter);
  receiver_ = std::make_unique<ReceiverBridge>(GetHandle(), registrar->messenger(), registrar->texture_registrar(),
      [this](const Map& snapshot) { UpdateSnapshot(snapshot); }, adapter);
  if (adapter) adapter->Release();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  SetThreadExecutionState(ES_CONTINUOUS);
  if (presentation_) { presentation_->SetMethodCallHandler(nullptr); presentation_.reset(); }
  receiver_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == ReceiverBridge::kDispatchMessage && receiver_) {
    receiver_->Dispatch();
    return 0;
  }
  if (message == kShowWindowMessage) { ShowApp(); return 0; }
  if (message == WM_CLOSE) { CloseAppWindow(); return 0; }
  if (message == WM_QUERYENDSESSION) return TRUE;
  if (message == WM_ENDSESSION && wparam) { DestroyWindow(hwnd); return 0; }
  if (message == kFullscreenStateMessage) { FullscreenChanged(); return 0; }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  const auto result = Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  if (message == WM_STYLECHANGED && wparam == static_cast<WPARAM>(GWL_STYLE)) {
    const auto* styles = reinterpret_cast<const STYLESTRUCT*>(lparam);
    if ((styles->styleOld ^ styles->styleNew) & WS_THICKFRAME) {
      // nativeapi reports ordinary window state. Bridge only fullscreen's
      // frame-style change, after the library has restored placement/styles.
      PostMessageW(hwnd, kFullscreenStateMessage, 0, 0);
    }
  }
  return result;
}

void FlutterWindow::Invoke(const char* method) {
  if (presentation_) presentation_->InvokeMethod(method, nullptr);
}

void FlutterWindow::FullscreenChanged() {
  if (presentation_) presentation_->InvokeMethod("windowStateChanged", std::make_unique<Value>(Map{
      {Value("maximized"), Value(IsZoomed(GetHandle()) != FALSE)}, {Value("fullscreen"), Value(IsFullscreen())}}));
}

void FlutterWindow::ShowApp() {
  if (desktop_ready_) Invoke("openApp");
  else { ShowWindow(GetHandle(), SW_SHOW); SetForegroundWindow(GetHandle()); }
}

void FlutterWindow::CloseAppWindow() {
  if (!quit_requested_ && hide_on_close_) Invoke("closeRequested");
  else DestroyWindow(GetHandle());
}

void FlutterWindow::UpdateSnapshot(const Map& snapshot) {
  SetThreadExecutionState(Playing(snapshot) ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED : ES_CONTINUOUS);
}
