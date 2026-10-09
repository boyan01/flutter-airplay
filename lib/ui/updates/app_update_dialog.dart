// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/app_updates.dart';
import '../widgets/app_update_strings.dart';
import '../tv_focus.dart';
import '../widgets/receiver_strings.dart';

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.updates,
    required this.currentVersion,
    required this.connected,
    this.television = false,
  });

  final AppUpdates updates;
  final String currentVersion;
  final bool connected;
  final bool television;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  final _scroll = ScrollController();
  AppUpdates get updates => widget.updates;
  String get currentVersion => widget.currentVersion;
  bool get connected => widget.connected;
  bool get television => widget.television;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

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
        UpdateStatus.ready =>
          (updates.requiresSystemInstall
              ? strings.installUpdate
              : strings.installAndRestart),
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
        constraints: BoxConstraints(maxWidth: television ? 560 : 400),
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
                    autofocus: television,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
            Flexible(
              child: TvFocus(
                child: Focus(
                  key: const Key('appUpdateContentFocus'),
                  canRequestFocus: television,
                  onKeyEvent: (node, event) {
                    if (!television || event is KeyUpEvent) {
                      return KeyEventResult.ignored;
                    }
                    final direction =
                        event.logicalKey == LogicalKeyboardKey.arrowDown
                        ? 1
                        : event.logicalKey == LogicalKeyboardKey.arrowUp
                        ? -1
                        : 0;
                    if (direction == 0) return KeyEventResult.ignored;
                    final position = _scroll.position;
                    final offset =
                        (position.pixels +
                                direction * position.viewportDimension * 0.6)
                            .clamp(
                              position.minScrollExtent,
                              position.maxScrollExtent,
                            );
                    if (offset == position.pixels) {
                      return KeyEventResult.ignored;
                    }
                    position.jumpTo(offset);
                    return KeyEventResult.handled;
                  },
                  child: SingleChildScrollView(
                    controller: _scroll,
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
                            Text(
                              updates.requiresSystemInstall
                                  ? strings.androidUpdateInstallHelp
                                  : strings.updateRestartHelp,
                            ),
                            if (connected) ...[
                              const SizedBox(height: 12),
                              Text(
                                updates.requiresSystemInstall
                                    ? strings.androidUpdateInterruptMessage
                                    : strings.updateInterruptMessage,
                                key: const Key('updateInterruptWarning'),
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
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
                            Text(
                              notes!,
                              key: const Key('appUpdateReleaseNotes'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: OverflowBar(
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
                      child: Text(primaryLabel, textAlign: TextAlign.center),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
