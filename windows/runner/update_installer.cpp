// SPDX-License-Identifier: GPL-3.0-or-later
#include "update_installer.h"

#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <filesystem>
#include <stdexcept>
#include <vector>

namespace {
struct Handle {
  HANDLE value;
  ~Handle() { if (value != INVALID_HANDLE_VALUE && value) CloseHandle(value); }
};
std::wstring ExecutablePath() {
  std::wstring path(32768, L'\0');
  DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!length || length >= path.size()) throw std::runtime_error("Cannot locate this installation.");
  path.resize(length);
  return path;
}
std::wstring Wide(const std::string& value) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (!length) throw std::runtime_error("Invalid installer path.");
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), length);
  return result;
}
std::string HashFile(HANDLE file) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
    throw std::runtime_error("Cannot initialize update verification.");
  BCRYPT_HASH_HANDLE hash = nullptr;
  NTSTATUS status = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0);
  std::array<unsigned char, 65536> buffer;
  DWORD count = 0;
  bool read_ok = true;
  while (status >= 0) {
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr)) { read_ok = false; break; }
    if (!count) break;
    status = BCryptHashData(hash, buffer.data(), count, 0);
  }
  std::array<unsigned char, 32> digest{};
  if (status >= 0 && read_ok) status = BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0);
  if (hash) BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (status < 0 || !read_ok) throw std::runtime_error("Cannot verify update installer.");
  constexpr char hex[] = "0123456789abcdef";
  std::string result;
  for (const auto byte : digest) { result += hex[byte >> 4]; result += hex[byte & 15]; }
  return result;
}
}

bool CanInstallUpdate() {
  wchar_t location[32768]{};
  DWORD size = sizeof(location);
  const auto status = RegGetValueW(HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{D8393B77-9CE5-4D58-8CAC-2BD0621E7C16}_is1",
      L"InstallLocation", RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, location, &size);
  if (status != ERROR_SUCCESS) return false;
  try {
    return std::filesystem::equivalent(std::filesystem::path(location) / L"flutter_airplay.exe", ExecutablePath());
  } catch (...) { return false; }
}

void StartUpdateInstaller(const std::string& path, const std::string& sha256) {
  if (!CanInstallUpdate()) throw std::runtime_error("Updates require the registered Windows installation.");
  const auto installer = std::filesystem::path(Wide(path));
  if (!installer.is_absolute() || installer.extension() != L".exe" || path.find('"') != std::string::npos)
    throw std::runtime_error("Invalid update installer path.");
  // Deny writes/deletion between the final digest check and process creation.
  Handle file{CreateFileW(installer.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                          FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr)};
  if (file.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot open update installer.");
  BY_HANDLE_FILE_INFORMATION info{};
  if (!GetFileInformationByHandle(file.value, &info) || (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) || HashFile(file.value) != sha256)
    throw std::runtime_error("Update installer checksum mismatch.");
  const auto directory = std::filesystem::path(ExecutablePath()).parent_path();
  const auto log = installer.parent_path() / L"install.log";
  std::wstring command = L"\"" + installer.wstring() + L"\" /SILENT /NORESTART /NOCLOSEAPPLICATIONS /AIRPLAYUPDATE=1 /UPDATEPID=" +
      std::to_wstring(GetCurrentProcessId()) + L" /DIR=\"" + directory.wstring() + L"\" /LOG=\"" + log.wstring() + L"\"";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(installer.c_str(), command.data(), nullptr, nullptr, FALSE, 0, nullptr, directory.c_str(), &startup, &process))
    throw std::runtime_error("Cannot start update installer. The application has not exited.");
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
}
