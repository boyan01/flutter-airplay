#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <filesystem>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE instance_mutex = CreateMutexW(nullptr, FALSE, L"Local\\FlutterAirPlay.MainWindow");
  if (!instance_mutex) return EXIT_FAILURE;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Flutter AirPlay");
    if (existing) {
      DWORD process = 0; GetWindowThreadProcessId(existing, &process);
      AllowSetForegroundWindow(process);
      PostMessageW(existing, FlutterWindow::kShowWindowMessage, 0, 0);
    }
    CloseHandle(instance_mutex); return EXIT_SUCCESS;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Login launches do not inherit the installation's working directory.
  std::wstring executable(32768, L'\0');
  const auto length = GetModuleFileNameW(nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (!length || length >= executable.size()) { CloseHandle(instance_mutex); return EXIT_FAILURE; }
  executable.resize(length);
  flutter::DartProject project((std::filesystem::path(executable).parent_path() / L"data").wstring());

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(440, 560);
  if (!window.Create(L"Flutter AirPlay", origin, size)) {
    CloseHandle(instance_mutex); return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  window.Destroy();
  CloseHandle(instance_mutex);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
