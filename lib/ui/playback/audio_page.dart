// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../receiver/receiver_model.dart';
import '../widgets/receiver_strings.dart';
import '../tv_focus.dart';

class AudioPage extends StatelessWidget {
  const AudioPage({
    super.key,
    required this.model,
    required this.actionFocus,
    required this.onSettings,
  });
  final ReceiverModel model;
  final FocusNode actionFocus;
  final Future<void> Function({bool editName}) onSettings;

  @override
  Widget build(BuildContext context) {
    final strings = l10n(context);
    final colors = Theme.of(context).colorScheme;
    final tv = model.isTelevision;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) actionFocus.requestFocus();
      },
      child: Column(
        key: const Key('audioPage'),
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tv ? 40 : 16),
            child: Row(
              children: [
                Expanded(
                  child: model.platform == 'macos'
                      ? const SizedBox()
                      : const Text(
                          'Flutter AirPlay',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                ),
                TvFocus(
                  child: IconButton(
                    key: const Key('openSettings'),
                    focusNode: actionFocus,
                    tooltip: strings.settings,
                    onPressed: () => onSettings(),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: EdgeInsets.all(tv ? 40 : 24),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: tv ? 96 : 80,
                              height: tv ? 96 : 80,
                              decoration: BoxDecoration(
                                color: colors.primary.withValues(alpha: .1),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                model.audioPlaying
                                    ? Icons.graphic_eq_rounded
                                    : Icons.pause_rounded,
                                color: colors.primary,
                                size: tv ? 48 : 40,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                model.videoPaused
                                    ? strings.videoPaused
                                    : strings.audioPlaying,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: tv ? 32 : 26,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              strings.clientConnected(
                                model.clientName ?? 'iPhone',
                              ),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: tv ? 20 : 15,
                                color: colors.primary,
                              ),
                            ),
                            if (model.videoPaused && model.audioPlaying) ...[
                              const SizedBox(height: 8),
                              Text(
                                strings.audioContinues,
                                style: TextStyle(fontSize: tv ? 20 : 15),
                              ),
                            ],
                            const SizedBox(height: 24),
                            Text(
                              model.videoPaused
                                  ? strings.videoResumeHelp
                                  : strings.audioOnlyHelp,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: tv ? 18 : 14,
                                height: 1.6,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 32),
                            TvFocus(
                              child: OutlinedButton.icon(
                                key: const Key('disconnect'),
                                onPressed: model.canStop
                                    ? model.disconnect
                                    : null,
                                icon: const Icon(Icons.eject_rounded),
                                label: Text(strings.disconnect),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
