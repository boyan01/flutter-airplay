// SPDX-License-Identifier: GPL-3.0-only
// Exercises the policy called by main.cpp and FlutterWindow. Real HWND/process
// and registry wiring is covered by scripts/test_native.sh windows installer.
#include "../runner/desktop_startup.h"

#include <cstdio>
#include <stdexcept>

namespace {
using airplay::windows::DesktopStartup;
using airplay::windows::HandleDuplicateLaunch;
using airplay::windows::IsLoginLaunch;
using airplay::windows::IsOwnedLoginCommand;
using airplay::windows::LegacyLoginCommand;
using airplay::windows::LoginStartupCommand;
using airplay::windows::NeedsLoginCommandMigration;
using airplay::windows::StartupApprovalEnabled;

void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void LaunchArguments() {
  Check(!IsLoginLaunch({}), "no arguments must select manual startup");
  Check(IsLoginLaunch({"--launch-at-login"}), "login argument was ignored");
  Check(IsLoginLaunch({"--other", "--launch-at-login"}), "login argument requires a fixed position");
  Check(!IsLoginLaunch({"--launch-at-login=false", "--launch-at-login-extra"}), "login argument matched a prefix");
  Check(!IsLoginLaunch({"--LAUNCH-AT-LOGIN"}), "unknown argument selects login startup");
}

void StartupPresentation() {
  DesktopStartup manual(false);
  Check(!manual.finished(), "manual startup finished before the tray callback");
  Check(manual.Finish(true), "cold manual startup stays hidden with a tray");
  Check(manual.finished(), "manual startup did not finish");
  Check(!manual.Finish(true), "duplicate ready callback reopens a manually closed window");

  DesktopStartup login(true);
  Check(!login.Finish(true), "cold login startup presents a window with a usable tray");
  Check(login.finished(), "hidden login startup did not finish");
  Check(!login.Finish(true), "duplicate login ready callback presents the window");

  DesktopStartup reopened_login(true);
  reopened_login.RequestOpen();
  Check(!reopened_login.finished(), "pending manual reopen prematurely finishes startup");
  Check(reopened_login.Finish(true), "manual reopen before ready was lost");
  Check(!reopened_login.Finish(true), "duplicate callback repeats a pending reopen");

  for (const bool login_launch : {false, true}) {
    DesktopStartup unavailable(login_launch);
    Check(unavailable.Finish(false), "unavailable tray or timer failure stranded the window");
    Check(!unavailable.Finish(true), "late tray success repeated the fallback presentation");
    unavailable.RequestOpen();
    Check(unavailable.finished(), "reopen reset finished startup");
  }

  DesktopStartup tray_lost(true);
  Check(!tray_lost.Finish(true), "login must initially remain hidden");
  Check(tray_lost.Finish(false), "later tray failure must expose the hidden app");
}

void DuplicateLaunch() {
  unsigned finds = 0, opens = 0, waited = 0;
  auto wait = [&](unsigned milliseconds) { waited += milliseconds; };
  Check(HandleDuplicateLaunch(true, [&] { ++finds; return 1; },
      [&](int) { ++opens; return true; }, wait), "login duplicate failed");
  Check(finds == 0 && opens == 0 && waited == 0,
        "login duplicate inspected/activated a window or waited");

  Check(HandleDuplicateLaunch(false, [&] { ++finds; return 1; },
      [&](int) { ++opens; return true; }, wait), "manual duplicate did not open an existing HWND");
  Check(finds == 1 && opens == 1 && waited == 0, "ready HWND was not opened immediately");

  // Model the real race: the mutex owner is a login process whose HWND does not
  // yet exist. The exact dispatcher used in main.cpp must deliver the manual
  // intent once it appears, before Flutter commits to hidden startup.
  finds = opens = waited = 0;
  DesktopStartup pending_login(true);
  Check(HandleDuplicateLaunch(false, [&] { return ++finds < 4 ? 0 : 1; },
      [&](int) { ++opens; pending_login.RequestOpen(); return true; }, wait),
      "manual duplicate lost its intent before HWND creation");
  Check(finds == 4 && opens == 1 && waited == 150, "pending HWND polling did not stop when ready");
  Check(pending_login.Finish(true), "pending manual duplicate allowed login startup to stay hidden");

  finds = opens = waited = 0;
  Check(!HandleDuplicateLaunch(false, [&] { ++finds; return 0; },
      [&](int) { ++opens; return true; }, wait), "missing HWND reported a successful manual open");
  Check(finds == 101 && opens == 0 && waited == 5000,
        "manual duplicate did not obey its five-second wait bound");
  Check(!HandleDuplicateLaunch(false, [] { return 1; }, [](int) { return false; }, wait),
        "failed message delivery reported a successful manual open");
}

void LoginRegistration() {
  const std::wstring executable = L"C:\\Users\\Test User\\Apps\\Flutter AirPlay\\flutter_airplay.exe";
  const auto legacy = LegacyLoginCommand(executable);
  const auto command = LoginStartupCommand(executable);
  Check(legacy == L"\"C:\\Users\\Test User\\Apps\\Flutter AirPlay\\flutter_airplay.exe\"", "legacy command quoting changed");
  Check(command == legacy + L" --launch-at-login", "login registration omitted the exact argument");
  Check(IsOwnedLoginCommand(legacy, executable), "legacy enabled status was lost");
  Check(IsOwnedLoginCommand(command, executable), "new enabled status was lost");
  Check(NeedsLoginCommandMigration(legacy, executable, true), "enabled exact legacy entry was not migrated");
  Check(!NeedsLoginCommandMigration(command, executable, true), "current command migrated repeatedly");
  for (const auto& unrelated : {std::wstring(), executable,
                              legacy + L" --custom", command + L" --custom",
                              LoginStartupCommand(L"C:\\another\\flutter_airplay.exe"),
                              LegacyLoginCommand(L"C:\\another\\flutter_airplay.exe")}) {
    Check(!IsOwnedLoginCommand(unrelated, executable), "foreign/custom/missing command reported owned");
    Check(!NeedsLoginCommandMigration(unrelated, executable, true), "foreign/custom/missing command migrated");
  }
  for (const uint32_t state : {0u, 2u, 6u}) {
    Check(StartupApprovalEnabled(state), "known enabled approval was lost");
  }
  for (const uint32_t state : {1u, 3u, 4u, 7u, 99u}) {
    Check(!StartupApprovalEnabled(state), "disabled/unknown approval was accepted");
    Check(!NeedsLoginCommandMigration(legacy, executable, StartupApprovalEnabled(state)),
          "disabled/unknown approval permits migration");
  }
}
}  // namespace

int main() {
  try {
    LaunchArguments();
    StartupPresentation();
    DuplicateLaunch();
    LoginRegistration();
    std::puts("Windows desktop startup policy: OK");
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
