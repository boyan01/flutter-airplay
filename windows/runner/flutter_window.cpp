#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <windowsx.h>
#include <flutter/standard_method_codec.h>
#include "resource.h"
#include <flutter/plugin_registrar_windows.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kTrayMessage = WM_APP + 75;
constexpr UINT_PTR kAutoHideTimer = 1, kTrayRetryTimer = 2;
const GUID kTrayGuid{0x752ca42e, 0xc8e6, 0x4c20, {0x89, 0xb2, 0xd6, 0xaf, 0x9b, 0x83, 0x7d, 0x21}};

std::string String(const Map& values, const char* key, const char* fallback = "") {
  const auto found = values.find(Value(key));
  return found != values.end() && std::holds_alternative<std::string>(found->second)
      ? std::get<std::string>(found->second) : fallback;
}
bool Boolean(const Map& values, const char* key, bool fallback) {
  const auto found = values.find(Value(key));
  return found != values.end() && std::holds_alternative<bool>(found->second)
      ? std::get<bool>(found->second) : fallback;
}
int Integer(const Map& values, const char* key) {
  const auto found = values.find(Value(key));
  if (found == values.end()) return 0;
  if (std::holds_alternative<int32_t>(found->second)) return std::get<int32_t>(found->second);
  if (std::holds_alternative<int64_t>(found->second)) return static_cast<int>(std::get<int64_t>(found->second));
  return 0;
}
std::wstring Wide(const std::string& value) {
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size);
  return result;
}
bool Playing(const Map& snapshot) { return Integer(snapshot, "videoWidth") > 0 && Integer(snapshot, "videoHeight") > 0; }
bool Active(const std::string& status) { return status == "checking" || status == "starting" || status == "waiting" || status == "streaming" || status == "stopping"; }
bool Transitioning(const std::string& status) { return status == "checking" || status == "starting" || status == "stopping"; }

HICON AirplayIcon(DWORD color) {
  // A native 32-bit AirPlay symbol stays legible on light and dark taskbars.
  constexpr int size = 32;
  BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size; info.bmiHeader.biHeight = -size;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
  void* data = nullptr;
  HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &data, nullptr, 0);
  if (!bitmap) return nullptr;
  auto* pixels = static_cast<DWORD*>(data);
  for (int y = 0; y < size; ++y) for (int x = 0; x < size; ++x) {
    const bool frame = ((y >= 4 && y < 7) && x >= 3 && x <= 28)
        || ((x >= 3 && x < 6 || x >= 26 && x <= 28) && y >= 4 && y <= 22)
        || (y >= 20 && y <= 22 && (x >= 3 && x < 10 || x > 22 && x <= 28));
    const bool triangle = y >= 17 && y <= 28 && x >= 16 - (y - 17) && x <= 16 + (y - 17);
    pixels[y * size + x] = frame || triangle ? 0xff000000 | color : 0;
  }
  const BYTE mask_bytes[128]{};
  HBITMAP mask = CreateBitmap(size, size, 1, 1, mask_bytes);
  ICONINFO icon{TRUE, 0, 0, mask, bitmap};
  HICON result = mask ? CreateIconIndirect(&icon) : nullptr;
  if (mask) DeleteObject(mask); DeleteObject(bitmap);
  return result;
}
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
      "org.flutterairplay/window", &flutter::StandardMethodCodec::GetInstance());
  presentation_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result) {
    Map args;
    if (call.arguments() && std::holds_alternative<Map>(*call.arguments())) args = std::get<Map>(*call.arguments());
    const auto& method = call.method_name();
    if (method == "toggleFullscreen") { SetFullscreen(!IsFullscreen()); WindowStateChanged(); }
    else if (method == "exitFullscreen") { SetFullscreen(false); WindowStateChanged(); }
    else if (method == "toggleMaximize") { ToggleMaximize(); WindowStateChanged(); }
    else if (method == "minimizeWindow") ShowWindow(GetHandle(), SW_MINIMIZE);
    else if (method == "quitApp") { quit_requested_ = true; PostMessageW(GetHandle(), WM_CLOSE, 0, 0); }
    else if (method == "closeWindow") PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
    else if (method == "startDragging") {
      if (!IsFullscreen()) {
        POINT cursor{};
        if (GetCursorPos(&cursor)) {
          ReleaseCapture();
          SendMessageW(GetHandle(), WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(cursor.x, cursor.y));
        }
      }
    } else if (method == "setMode") SetMode(Integer(args, "width"), Integer(args, "height"));
    else if (method == "setStrings") {
      for (const auto& entry : args) {
        if (std::holds_alternative<std::string>(entry.first) && std::holds_alternative<std::string>(entry.second))
          strings_[std::get<std::string>(entry.first)] = Wide(std::get<std::string>(entry.second));
      }
      UpdateTray();
    } else { result->NotImplemented(); return; }
    result->Success();
  });
  receiver_ = std::make_unique<ReceiverBridge>(GetHandle(), registrar->messenger(), registrar->texture_registrar(),
      [this](const Map& snapshot) { UpdateSnapshot(snapshot); });
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  UpdateTray();
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
  KillTimer(GetHandle(), kAutoHideTimer); KillTimer(GetHandle(), kTrayRetryTimer);
  SetThreadExecutionState(ES_CONTINUOUS);
  if (tray_added_) {
    NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = GetHandle();
    icon.uFlags = NIF_GUID; icon.guidItem = kTrayGuid; Shell_NotifyIconW(NIM_DELETE, &icon); tray_added_ = false;
  }
  if (tray_icon_) { DestroyIcon(tray_icon_); tray_icon_ = nullptr; }
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
  if (taskbar_created_ && message == taskbar_created_) {
    tray_added_ = false; UpdateTray();
    if (!tray_added_ && !IsWindowVisible(hwnd)) ShowApp();
    return 0;
  }
  if (message == kTrayMessage) {
    const auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT) ShowApp();
    else if (event == WM_CONTEXTMENU) {
      POINT point{GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)};
      if (point.x == -1 && point.y == -1) GetCursorPos(&point);
      TrayMenu(point);
    }
    return 0;
  }
  if (message == WM_CLOSE) { CloseAppWindow(); return 0; }
  if (message == WM_QUERYENDSESSION) return TRUE;
  if (message == WM_ENDSESSION && wparam) { DestroyWindow(hwnd); return 0; }
  if (message == WM_TIMER && wparam == kAutoHideTimer) {
    KillTimer(hwnd, kAutoHideTimer);
    if (!Playing(snapshot_) && opened_for_session_) HideApp(false);
    return 0;
  }
  if (message == WM_TIMER && wparam == kTrayRetryTimer) { UpdateTray(); return 0; }
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
  if (message == WM_SIZE) WindowStateChanged();
  return result;
}

std::wstring FlutterWindow::Text(const char* key) const {
  const auto found = strings_.find(key);
  return found == strings_.end() ? Wide(key) : found->second;
}

void FlutterWindow::Invoke(const char* method) {
  if (presentation_) presentation_->InvokeMethod(method, nullptr);
}

void FlutterWindow::WindowStateChanged() {
  if (presentation_) presentation_->InvokeMethod("windowStateChanged", std::make_unique<Value>(Map{
      {Value("maximized"), Value(IsZoomed(GetHandle()) != FALSE)}, {Value("fullscreen"), Value(IsFullscreen())}}));
}

void FlutterWindow::ShowApp(bool user_initiated) {
  if (user_initiated) { KillTimer(GetHandle(), kAutoHideTimer); opened_for_session_ = false; }
  ShowWindow(GetHandle(), IsIconic(GetHandle()) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::HideApp(bool disconnect) {
  KillTimer(GetHandle(), kAutoHideTimer); opened_for_session_ = false;
  if (disconnect && String(snapshot_, "status") == "streaming") Invoke("disconnectSession");
  ShowWindow(GetHandle(), SW_HIDE);
}

void FlutterWindow::CloseAppWindow() {
  if (!quit_requested_ && tray_added_ && Boolean(snapshot_, "keepInMenuBar", true)) HideApp(true);
  else DestroyWindow(GetHandle());
}

void FlutterWindow::UpdateSnapshot(const Map& snapshot) {
  snapshot_ = snapshot;
  const bool playing = Playing(snapshot_);
  SetThreadExecutionState(playing ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED : ES_CONTINUOUS);
  if (playing && !was_playing_) {
    KillTimer(GetHandle(), kAutoHideTimer);
    if ((!IsWindowVisible(GetHandle()) || IsIconic(GetHandle())) && Boolean(snapshot_, "showOnConnect", true)) {
      opened_for_session_ = true; ShowApp(false);
    }
    if (Boolean(snapshot_, "fullscreenOnConnect", false)) SetFullscreen(true);
  } else if (!playing && was_playing_ && opened_for_session_) {
    SetTimer(GetHandle(), kAutoHideTimer, 3000, nullptr);
  }
  SetWindowPos(GetHandle(), playing && Boolean(snapshot_, "alwaysOnTop", false) ? HWND_TOPMOST : HWND_NOTOPMOST,
      0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  was_playing_ = playing;
  UpdateTray();
}

void FlutterWindow::UpdateTray() {
  const auto status = String(snapshot_, "status", "stopped");
  const DWORD color = status == "error" ? 0xf06a6a : Transitioning(status) || status == "streaming" && !Playing(snapshot_)
      ? 0xe4b55e : Playing(snapshot_) || Boolean(snapshot_, "audioPlaying", false) ? 0x7dd7c6 : 0xa0a9ae;
  HICON previous = nullptr;
  if (!tray_icon_ || tray_color_ != color) {
    HICON next = AirplayIcon(color);
    if (next) { previous = tray_icon_; tray_icon_ = next; tray_color_ = color; }
  }
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = GetHandle();
  icon.uFlags = NIF_GUID | NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  icon.guidItem = kTrayGuid; icon.uCallbackMessage = kTrayMessage; icon.hIcon = tray_icon_;
  const auto label = Text(status == "error" ? "unavailable" : Transitioning(status) ? "starting" : Playing(snapshot_)
      ? "playing" : Boolean(snapshot_, "audioPlaying", false) ? "audioPlaying" : Active(status) ? "discoverable" : "off");
  const auto tooltip = Wide(String(snapshot_, "name", "Flutter AirPlay")) + L" · " + label;
  wcsncpy_s(icon.szTip, tooltip.c_str(), _TRUNCATE);
  if (tray_added_) Shell_NotifyIconW(NIM_MODIFY, &icon);
  else if (tray_icon_ && Shell_NotifyIconW(NIM_ADD, &icon)) {
    icon.uVersion = NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION, &icon);
    tray_added_ = true; KillTimer(GetHandle(), kTrayRetryTimer);
  } else SetTimer(GetHandle(), kTrayRetryTimer, 2000, nullptr);
  if (previous) DestroyIcon(previous);
}

void FlutterWindow::TrayMenu(POINT point) {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  const auto status = String(snapshot_, "status", "stopped");
  const bool playing = Playing(snapshot_), connected = status == "streaming";
  const auto add = [&](UINT id, const std::wstring& label, bool enabled = true, bool checked = false) {
    AppendMenuW(menu, MF_STRING | (enabled ? MF_ENABLED : MF_GRAYED) | (checked ? MF_CHECKED : 0), id, label.c_str());
  };
  add(0, Wide(String(snapshot_, "name", "Flutter AirPlay")), false);
  add(0, status == "error" ? Wide(String(snapshot_, "message")) : Text(playing ? "playing" : Boolean(snapshot_, "audioPlaying", false)
      ? "audioPlaying" : Transitioning(status) ? "starting" : Active(status) ? "discoverable" : "off"), false);
  if (playing) add(0, std::to_wstring(Integer(snapshot_, "videoWidth")) + L" × " + std::to_wstring(Integer(snapshot_, "videoHeight")), false);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  add(1, Text(playing ? "showPlayer" : "openApp"));
  add(2, Text("receive"), !Transitioning(status), Active(status));
  if (connected) add(3, Text("disconnect"));
  if (playing) {
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    add(7, Text(IsFullscreen() ? "exitFullscreen" : "enterFullscreen"));
    add(8, Text("actualSize"), !IsFullscreen()); add(9, Text("fitScreen"), !IsFullscreen());
    add(10, Text("alwaysOnTop"), true, Boolean(snapshot_, "alwaysOnTop", false));
  }
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  add(4, Text("settings")); add(5, Text("logs"));
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr); add(6, Text("quitApp"));
  HWND owner = GetHandle();
  HWND popup_owner = nullptr;
  if (!IsWindowVisible(owner) || IsIconic(owner)) {
    // TrackPopupMenu needs a foreground owner even while the receiver is hidden.
    popup_owner = CreateWindowExW(WS_EX_TOOLWINDOW, L"STATIC", L"", WS_POPUP,
        point.x, point.y, 0, 0, owner, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!popup_owner) { DestroyMenu(menu); return; }
    ShowWindow(popup_owner, SW_SHOW);
    owner = popup_owner;
  }
  SetForegroundWindow(owner);
  const auto selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, owner, nullptr);
  DestroyMenu(menu); PostMessageW(owner, WM_NULL, 0, 0);
  if (popup_owner) DestroyWindow(popup_owner);
  switch (selected) {
    case 1: ShowApp(); break;
    case 2: Invoke("toggleReceiver"); break;
    case 3: Invoke("disconnectSession"); break;
    case 4: ShowApp(); Invoke("openSettings"); break;
    case 5: ShowApp(); Invoke("openLogs"); break;
    case 6: DestroyWindow(GetHandle()); break;
    case 7: SetFullscreen(!IsFullscreen()); WindowStateChanged(); break;
    case 8: ResizePlayer(true); break;
    case 9: ResizePlayer(false); break;
    case 10: Invoke("toggleOnTop"); break;
  }
}
