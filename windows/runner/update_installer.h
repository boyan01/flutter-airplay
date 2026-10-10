// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef RUNNER_UPDATE_INSTALLER_H_
#define RUNNER_UPDATE_INSTALLER_H_
#include <string>

// Only the current user's registered Inno installation may update in place.
bool CanInstallUpdate();
void StartUpdateInstaller(const std::string& path, const std::string& sha256);
#endif
