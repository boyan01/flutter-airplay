// SPDX-License-Identifier: GPL-3.0-or-later
import '../../l10n/generated/app_localizations.dart';
import '../../platform/app_updates.dart';

String updateActionLabel(
  AppLocalizations strings,
  AppUpdates updates, {
  bool tray = false,
}) {
  if (updates.checking) return strings.checkingForUpdates;
  if (updates.status == UpdateStatus.ready) {
    return (updates.requiresSystemInstall
        ? strings.installUpdate
        : strings.installAndRestart);
  }
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

/// Select the changelog section after hosts have converted feed HTML to text.
/// Older feeds without language headings retain their original content.
String localizedUpdateNotes(String? notes, String languageCode) {
  final text = notes?.trim() ?? '';
  final headings = RegExp(
    r'^[ \t]*(?:###[ \t]+)?(中文|English)[ \t]*\r?$',
    multiLine: true,
  ).allMatches(text).toList();
  if (headings.isEmpty) return text;

  final sections = <String, String>{};
  for (var index = 0; index < headings.length; index++) {
    final heading = headings[index];
    final end = index + 1 < headings.length
        ? headings[index + 1].start
        : text.length;
    final content = text.substring(heading.end, end).trim();
    if (content.isNotEmpty) sections[heading.group(1)!] = content;
  }
  return sections[languageCode == 'zh' ? '中文' : 'English'] ??
      sections['English'] ??
      sections['中文'] ??
      text;
}
