// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../platform/app_updates.dart';
import '../widgets/app_update_strings.dart';
import '../widgets/receiver_strings.dart';

class AppUpdateSettings extends StatelessWidget {
  const AppUpdateSettings({
    super.key,
    required this.updates,
    this.onOpenUpdate,
  });

  final AppUpdates updates;
  final VoidCallback? onOpenUpdate;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) {
      final strings = l10n(context);
      final theme = Theme.of(context);
      final available =
          updates.initialized && updates.supported && updates.enabled;
      final showUpdate =
          updates.hasUpdate ||
          switch (updates.status) {
            UpdateStatus.available ||
            UpdateStatus.downloading ||
            UpdateStatus.extracting ||
            UpdateStatus.ready ||
            UpdateStatus.installing => true,
            _ => false,
          };
      final busy = switch (updates.status) {
        UpdateStatus.checking ||
        UpdateStatus.extracting ||
        UpdateStatus.installing => true,
        _ => false,
      };
      final diagnostic = updates.error ?? updates.unavailableReason;
      final status = updateStatusLabel(strings, updates);
      final title = !available
          ? strings.checkForUpdates
          : switch (updates.status) {
              UpdateStatus.idle => strings.checkForUpdates,
              UpdateStatus.ready => strings.installAndRestart,
              UpdateStatus.error =>
                showUpdate ? strings.viewUpdate : strings.retryUpdateCheck,
              _ => status,
            };
      final subtitle = title != status
          ? status
          : switch (updates.status) {
              UpdateStatus.available => strings.viewUpdate,
              UpdateStatus.downloading => strings.updateBackgroundDownload,
              _ => null,
            };
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(strings.appUpdates, style: theme.textTheme.titleSmall),
            SwitchListTile(
              key: const Key('automaticallyCheckForUpdates'),
              contentPadding: EdgeInsets.zero,
              title: Text(strings.automaticallyCheckForUpdates),
              subtitle: Text(
                updates.savingPreference
                    ? strings.saving
                    : strings.automaticallyCheckForUpdatesHelp,
              ),
              value: updates.automaticallyCheckForUpdates,
              onChanged: available && !updates.savingPreference
                  ? (value) => unawaited(
                      updates.setAutomaticallyCheckForUpdates(value),
                    )
                  : null,
            ),
            ListTile(
              key: const Key('appUpdateAction'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                available && updates.status == UpdateStatus.error
                    ? Icons.error_outline
                    : Icons.system_update_alt,
                size: 20,
              ),
              title: Text(title),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (subtitle != null)
                    Text(
                      subtitle,
                      key: const Key('appUpdateStatus'),
                      style: TextStyle(
                        color: available && updates.status != UpdateStatus.error
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.error,
                      ),
                    ),
                  if (diagnostic?.isNotEmpty == true)
                    Text(
                      diagnostic!,
                      key: const Key('appUpdateDiagnostic'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  if (updates.lastChecked != null)
                    Text(
                      strings.updateLastChecked(
                        DateFormat.yMd(strings.localeName)
                            .add_Hm()
                            .format(updates.lastChecked!.toLocal()),
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
              trailing: busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        key: const Key('appUpdateSpinner'),
                        strokeWidth: 2,
                        semanticsLabel: status,
                      ),
                    )
                  : const Icon(Icons.chevron_right, size: 20),
              onTap: available
                  ? showUpdate
                        ? onOpenUpdate
                        : updates.canCheck
                        ? () => unawaited(updates.check())
                        : null
                  : null,
            ),
          ],
        ),
      );
    },
  );
}
