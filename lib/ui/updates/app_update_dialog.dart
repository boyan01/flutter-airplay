// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import '../../platform/app_updates.dart';
import '../widgets/app_update_strings.dart';
import '../widgets/receiver_strings.dart';

class AppUpdateDialog extends StatelessWidget {
  const AppUpdateDialog({
    super.key,
    required this.updates,
    required this.currentVersion,
    required this.connected,
  });

  final AppUpdates updates;
  final String currentVersion;
  final bool connected;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) {
      final strings = l10n(context);
      final theme = Theme.of(context);
      final progress = updates.progress?.isFinite == true
          ? updates.progress!.clamp(0.0, 1.0)
          : null;
      final downloading = updates.status == UpdateStatus.downloading;
      final ready = updates.status == UpdateStatus.ready;
      final notes = updates.releaseNotes?.trim();
      final diagnostic = updates.error ?? updates.unavailableReason;
      final primaryLabel = switch (updates.status) {
        UpdateStatus.available => strings.downloadUpdate,
        UpdateStatus.ready => strings.installAndRestart,
        UpdateStatus.error => strings.retry,
        UpdateStatus.idle => strings.checkForUpdates,
        _ => null,
      };
      final VoidCallback? primaryAction = switch (updates.status) {
        UpdateStatus.available || UpdateStatus.ready =>
          updates.canInstall ? () => unawaited(updates.install()) : null,
        UpdateStatus.error =>
          updates.canInstall
              ? () => unawaited(updates.install())
              : updates.canCheck
              ? () => unawaited(updates.check())
              : updates.canShowUpdate
              ? () => unawaited(updates.showUpdate())
              : null,
        UpdateStatus.idle =>
          updates.canCheck ? () => unawaited(updates.check()) : null,
        _ => null,
      };
      return Dialog(
        key: const Key('appUpdateDialog'),
        constraints: const BoxConstraints(maxWidth: 400),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            strings.appUpdates,
                            style: theme.textTheme.titleLarge,
                          ),
                          if (currentVersion.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              strings.updateCurrentVersion(currentVersion),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('closeAppUpdate'),
                    tooltip: strings.close,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          updateStatusLabel(strings, updates),
                          key: const Key('appUpdateStatus'),
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      if (downloading) ...[
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          key: const Key('appUpdateProgress'),
                          value: progress,
                          semanticsLabel: strings.updateDownloading,
                          semanticsValue: progress == null
                              ? null
                              : '${(progress * 100).round()}%',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          strings.updateBackgroundDownload,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                      if (ready) ...[
                        const SizedBox(height: 12),
                        Text(strings.updateRestartHelp),
                        if (connected) ...[
                          const SizedBox(height: 12),
                          Text(
                            strings.updateInterruptMessage,
                            key: const Key('updateInterruptWarning'),
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ],
                      ],
                      if (diagnostic?.isNotEmpty == true) ...[
                        const SizedBox(height: 12),
                        Text(
                          diagnostic!,
                          key: const Key('appUpdateDiagnostic'),
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                      if (notes?.isNotEmpty == true) ...[
                        const SizedBox(height: 20),
                        Text(
                          strings.updateReleaseNotes,
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(notes!, key: const Key('appUpdateReleaseNotes')),
                      ],
                      const SizedBox(height: 24),
                      OverflowBar(
                        alignment: MainAxisAlignment.end,
                        spacing: 8,
                        overflowSpacing: 8,
                        overflowAlignment: OverflowBarAlignment.end,
                        children: [
                          if (downloading && updates.canCancel)
                            TextButton(
                              key: const Key('cancelAppUpdate'),
                              onPressed: () => unawaited(updates.cancel()),
                              child: Text(strings.cancelUpdateDownload),
                            )
                          else
                            TextButton(
                              key: const Key('deferAppUpdate'),
                              onPressed: () => Navigator.of(context).pop(),
                              child: Text(strings.updateLater),
                            ),
                          if (primaryLabel != null)
                            FilledButton(
                              key: const Key('appUpdatePrimaryAction'),
                              style: FilledButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                              ),
                              onPressed: primaryAction,
                              child: Text(
                                primaryLabel,
                                textAlign: TextAlign.center,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
