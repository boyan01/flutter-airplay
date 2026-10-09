// SPDX-License-Identifier: GPL-3.0-or-later
import '../../l10n/generated/app_localizations.dart';
import '../../platform/app_updates.dart';

String updateActionLabel(
  AppLocalizations strings,
  AppUpdates updates, {
  bool tray = false,
}) {
  if (updates.checking) return strings.checkingForUpdates;
  if (updates.status == UpdateStatus.ready) return strings.installAndRestart;
  if (updates.status == UpdateStatus.extracting) return strings.preparingUpdate;
  if (updates.status == UpdateStatus.installing) {
    return strings.installingUpdate;
  }
  if (updates.status == UpdateStatus.downloading) {
    return tray ? strings.updateDownloading : strings.viewUpdateProgress;
  }
  if (updates.hasUpdate || updates.status == UpdateStatus.available) {
    if (tray && updates.version?.isNotEmpty == true) {
      return strings.updateToVersion(updates.version!);
    }
    return strings.viewUpdate;
  }
  if (updates.status == UpdateStatus.error || updates.error != null) {
    return strings.retryUpdateCheck;
  }
  return strings.checkForUpdates;
}

String updateStatusLabel(AppLocalizations strings, AppUpdates updates) {
  if (!updates.initialized) return strings.updatesInitializing;
  if (!updates.supported || !updates.enabled) return strings.updatesUnavailable;
  if (updates.checking) return strings.checkingForUpdates;
  return switch (updates.status) {
    UpdateStatus.idle =>
      updates.lastChecked == null
          ? strings.updatesNotChecked
          : strings.updatesUpToDate,
    UpdateStatus.checking => strings.checkingForUpdates,
    UpdateStatus.available =>
      updates.version?.isNotEmpty == true
          ? strings.updateAvailable(updates.version!)
          : strings.updateAvailableUnknownVersion,
    UpdateStatus.downloading =>
      updates.progress?.isFinite == true
          ? strings.updateDownloadingProgress(
              (updates.progress!.clamp(0.0, 1.0) * 100).round(),
            )
          : strings.updateDownloading,
    UpdateStatus.extracting => strings.preparingUpdate,
    UpdateStatus.ready => strings.updateReady,
    UpdateStatus.installing => strings.installingUpdate,
    UpdateStatus.error =>
      updates.hasUpdate ? strings.updateFailed : strings.updateCheckFailed,
  };
}
