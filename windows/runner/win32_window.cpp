#include "win32_window.h"

#include <dwmapi.h>
#include <commctrl.h>
#include <windowsx.h>
#include <algorithm>
#include <cmath>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  MONITORINFO display{sizeof(MONITORINFO)};
  GetMonitorInfoW(monitor, &display);
  const int width = Scale(size.width, scale_factor), height = Scale(size.height, scale_factor);
  const int x = display.rcWork.left + (display.rcWork.right - display.rcWork.left - width) / 2;
  const int y = display.rcWork.top + (display.rcWork.bottom - display.rcWork.top - height) / 2;
  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      x, y, width, height,
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);
  const MARGINS shadow{1, 1, 1, 1};
  DwmExtendFrameIntoClientArea(window, &shadow);
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

void Win32Window::SetFullscreen(bool enabled) {
  if (fullscreen_ == enabled) return;
  if (enabled) {
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (!GetMonitorInfoW(MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST), &monitor)) return;
    windowed_style_ = GetWindowLongPtrW(window_handle_, GWL_STYLE);
    GetWindowPlacement(window_handle_, &windowed_placement_);
    fullscreen_ = true;
    SetWindowLongPtrW(window_handle_, GWL_STYLE, windowed_style_ & ~WS_OVERLAPPEDWINDOW);
    SetWindowPos(window_handle_, nullptr, monitor.rcMonitor.left, monitor.rcMonitor.top,
        monitor.rcMonitor.right - monitor.rcMonitor.left, monitor.rcMonitor.bottom - monitor.rcMonitor.top,
        SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOOWNERZORDER);
  } else {
    fullscreen_ = false;
    SetWindowLongPtrW(window_handle_, GWL_STYLE, windowed_style_);
    SetWindowPlacement(window_handle_, &windowed_placement_);
    SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
        SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER);
    ResizeContent();
  }
}

void Win32Window::ToggleMaximize() {
  if (fullscreen_) { SetFullscreen(false); return; }
  ShowWindow(window_handle_, IsZoomed(window_handle_) ? SW_RESTORE : SW_MAXIMIZE);
}

void Win32Window::SetMode(int width, int height) {
  if (player_width_ == width && player_height_ == height) return;
  player_width_ = width; player_height_ = height;
  ResizeContent();
}

void Win32Window::ResizeContent() {
  if (fullscreen_ || IsZoomed(window_handle_)) return;
  MONITORINFO monitor{sizeof(MONITORINFO)};
  if (!GetMonitorInfoW(MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST), &monitor)) return;
  RECT previous{}; GetWindowRect(window_handle_, &previous);
  const auto &work = monitor.rcWork;
  const double dpi = GetDpiForWindow(window_handle_) / 96.0;
  double width = 440 * dpi, height = 560 * dpi;
  if (player_width_ > 0 && player_height_ > 0) {
    const double ratio = double(player_width_) / player_height_;
    const double max_width = (work.right - work.left) * 0.8;
    const double max_height = (work.bottom - work.top) * 0.8;
    width = std::min(max_width, max_height * ratio);
    height = width / ratio;
  }
  const int w = std::min(static_cast<int>(std::round(width)), int(work.right - work.left));
  const int h = std::min(static_cast<int>(std::round(height)), int(work.bottom - work.top));
  const int x = std::clamp(int((previous.left + previous.right - w) / 2), int(work.left), int(work.right) - w);
  const int y = std::clamp(int((previous.top + previous.bottom - h) / 2), int(work.top), int(work.bottom) - h);
  SetWindowPos(window_handle_, nullptr, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
}

void Win32Window::ResizePlayer(bool actual_size) {
  if (!actual_size) { ResizeContent(); return; }
  if (fullscreen_ || player_width_ <= 0 || player_height_ <= 0) return;
  if (IsZoomed(window_handle_)) ShowWindow(window_handle_, SW_RESTORE);
  MONITORINFO monitor{sizeof(MONITORINFO)};
  if (!GetMonitorInfoW(MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST), &monitor)) return;
  RECT previous{}; GetWindowRect(window_handle_, &previous);
  const auto &work = monitor.rcWork;
  const double scale = std::min(1.0, std::min((work.right - work.left) * 0.8 / player_width_, (work.bottom - work.top) * 0.8 / player_height_));
  const int w = static_cast<int>(std::round(player_width_ * scale));
  const int h = static_cast<int>(std::round(player_height_ * scale));
  const int x = std::clamp(int((previous.left + previous.right - w) / 2), int(work.left), int(work.right) - w);
  const int y = std::clamp(int((previous.top + previous.bottom - h) / 2), int(work.top), int(work.bottom) - h);
  SetWindowPos(window_handle_, nullptr, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
}

LRESULT Win32Window::HitTest(LPARAM position) const {
  if (fullscreen_ || IsZoomed(window_handle_)) return HTCLIENT;
  RECT bounds{}; GetWindowRect(window_handle_, &bounds);
  const int border = GetSystemMetricsForDpi(SM_CXSIZEFRAME, GetDpiForWindow(window_handle_))
      + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, GetDpiForWindow(window_handle_));
  const int x = GET_X_LPARAM(position), y = GET_Y_LPARAM(position);
  const bool left = x < bounds.left + border, right = x >= bounds.right - border;
  const bool top = y < bounds.top + border, bottom = y >= bounds.bottom - border;
  if (top) return left ? HTTOPLEFT : right ? HTTOPRIGHT : HTTOP;
  if (bottom) return left ? HTBOTTOMLEFT : right ? HTBOTTOMRIGHT : HTBOTTOM;
  return left ? HTLEFT : right ? HTRIGHT : HTCLIENT;
}

LRESULT CALLBACK Win32Window::ChildProc(HWND window, UINT message, WPARAM wparam,
                                      LPARAM lparam, UINT_PTR id, DWORD_PTR context) {
  auto *host = reinterpret_cast<Win32Window *>(context);
  if (message == WM_NCHITTEST && host->HitTest(lparam) != HTCLIENT) return HTTRANSPARENT;
  if (message == WM_NCDESTROY) RemoveWindowSubclass(window, ChildProc, id);
  return DefSubclassProc(window, message, wparam, lparam);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCCALCSIZE:
      if (wparam) {
        if (!fullscreen_ && IsZoomed(hwnd)) {
          MONITORINFO monitor{sizeof(MONITORINFO)};
          if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor))
            reinterpret_cast<NCCALCSIZE_PARAMS *>(lparam)->rgrc[0] = monitor.rcWork;
        }
        return 0;
      }
      break;
    case WM_NCACTIVATE:
      return DefWindowProc(hwnd, message, wparam, -1);
    case WM_NCHITTEST:
      return HitTest(lparam);
    case WM_GETMINMAXINFO: {
      auto *size = reinterpret_cast<MINMAXINFO *>(lparam);
      const double scale = GetDpiForWindow(hwnd) / 96.0;
      int width = Scale(player_width_ > 0 ? 160 : 360, scale);
      int height = Scale(player_width_ > 0 ? 160 : 480, scale);
      if (player_width_ > 0 && player_height_ > 0) {
        const double ratio = double(player_width_) / player_height_;
        width = std::max(width, static_cast<int>(std::ceil(height * ratio)));
        height = std::max(height, static_cast<int>(std::ceil(width / ratio)));
      }
      size->ptMinTrackSize = {width, height};
      return 0;
    }
    case WM_SIZING:
      if (player_width_ > 0 && player_height_ > 0 && !fullscreen_) {
        auto *bounds = reinterpret_cast<RECT *>(lparam);
        const double ratio = double(player_width_) / player_height_;
        if (wparam == WMSZ_TOP || wparam == WMSZ_BOTTOM) {
          bounds->right = bounds->left + static_cast<LONG>(std::round((bounds->bottom - bounds->top) * ratio));
        } else {
          const LONG height = static_cast<LONG>(std::round((bounds->right - bounds->left) / ratio));
          if (wparam == WMSZ_TOPLEFT || wparam == WMSZ_TOPRIGHT) bounds->top = bounds->bottom - height;
          else bounds->bottom = bounds->top + height;
        }
        return TRUE;
      }
      break;
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  SetWindowSubclass(content, ChildProc, 1, reinterpret_cast<DWORD_PTR>(this));
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
