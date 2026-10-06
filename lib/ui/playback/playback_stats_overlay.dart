// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../receiver/receiver_model.dart';
import '../widgets/receiver_strings.dart';

/// Passive overlay; the shared playback worker supplies the measurements.
class PlaybackStatsOverlay extends StatelessWidget {
  const PlaybackStatsOverlay({super.key, required this.model});
  final ReceiverModel model;

  @override
  Widget build(BuildContext context) {
    final strings = l10n(context);
    final stats = model.playbackStats;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: DecoratedBox(
        key: const Key('playbackStatsOverlay'),
        decoration: BoxDecoration(
          color: const Color(0xcc000000),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: DefaultTextStyle(
            style: Theme.of(context).textTheme.bodySmall!
                .copyWith(color: Colors.white),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${model.videoWidth} × ${model.videoHeight}'),
                if (stats == null)
                  Text(strings.playbackStatsWaiting)
                else ...[
                  Text('${stats.codec} · ${stats.decoder}'),
                  Text(
                    '${strings.playbackStatsFps}: ${stats.fps.toStringAsFixed(1)}',
                  ),
                  Text('${strings.playbackStatsDropped}: ${stats.dropped}'),
                  Text('${strings.playbackStatsSubmitted}: ${stats.submitted}'),
                  Text('${strings.playbackStatsPending}: ${stats.pending}'),
                  Text('${strings.playbackStatsQueued}: ${stats.queued}'),
                ],
                const SizedBox(height: 4),
                Text(strings.playbackStatsHelp),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
