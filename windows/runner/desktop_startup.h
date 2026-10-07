// SPDX-License-Identifier: GPL-3.0-only
#ifndef RUNNER_DESKTOP_STARTUP_H_
#define RUNNER_DESKTOP_STARTUP_H_

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace airplay::windows {

// Only the app-owned login registration supplies this argument. A manual
// launch remains manual even when launch-at-login is enabled in Settings.
inline bool IsLoginLaunch(const std::vector<std::string>& arguments) {
  return std::find(arguments.begin(), arguments.end(), "--launch-at-login") != arguments.end();
}

// The singleton mutex exists before its owner creates the HWND. Give a manual
// duplicate a bounded chance to deliver its open request during that interval.
// A login duplicate must not wait, inspect windows, or request foreground focus.
inline constexpr unsigned kExistingWindowPollMilliseconds = 50;
inline constexpr unsigned kExistingWindowPollCount = 100;

template <typename FindWindow, typename RequestOpen, typename Wait>
bool HandleDuplicateLaunch(bool login_launch, FindWindow find_window,
                           RequestOpen request_open, Wait wait) {
  if (login_launch) return true;
  for (unsigned attempt = 0; attempt <= kExistingWindowPollCount; ++attempt) {
    const auto window = find_window();
    if (window) return request_open(window);
    if (attempt < kExistingWindowPollCount) wait(kExistingWindowPollMilliseconds);
  }
  // The first process may have crashed or be hung before creating its window.
  // Do not report that a manual open succeeded when no one received the intent.
  return false;
}

inline std::wstring LegacyLoginCommand(const std::wstring& executable) {
  return L"\"" + executable + L"\"";
}

inline std::wstring LoginStartupCommand(const std::wstring& executable) {
  return LegacyLoginCommand(executable) + L" --launch-at-login";
}

inline bool IsOwnedLoginCommand(const std::wstring& command, const std::wstring& executable) {
  return command == LoginStartupCommand(executable) || command == LegacyLoginCommand(executable);
}

inline bool StartupApprovalEnabled(uint32_t state) {
  // StartupApproved has no published enum: preserve the existing conservative
  // interpretation of the shell's enabled states; unknown states stay disabled.
  return state == 0 || state == 2 || state == 6;
}

inline bool NeedsLoginCommandMigration(const std::wstring& command,
                                      const std::wstring& executable, bool approved) {
  return approved && command == LegacyLoginCommand(executable);
}

// Presentation decisions shared by the real HWND host and its native fixture.
// Window/tray operations themselves remain in FlutterWindow.
class DesktopStartup {
 public:
  explicit DesktopStartup(bool login_launch) : login_launch_(login_launch) {}

  bool finished() const { return finished_; }
  void RequestOpen() { reopen_requested_ = true; }

  // Returns whether to present the window. A late successful tray callback
  // cannot undo a timeout/failure fallback or reopen an already-closed window.
  bool Finish(bool tray_available) {
    if (finished_ && tray_available) return false;
    finished_ = true;
    return !login_launch_ || !tray_available || reopen_requested_;
  }

 private:
  bool login_launch_;
  bool finished_ = false;
  bool reopen_requested_ = false;
};

}  // namespace airplay::windows

#endif  // RUNNER_DESKTOP_STARTUP_H_
