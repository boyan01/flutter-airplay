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
    final stats = model.playbackStats;
    final strings = l10n(context);
    final audio = stats == null
        ? ''
        : [
            stats.audioCodec,
            if (stats.audioSampleRate > 0)
              '${(stats.audioSampleRate / 1000).toStringAsFixed(1)} kHz',
            if (stats.audioChannels > 0) '${stats.audioChannels} ch',
          ].where((part) => part.isNotEmpty).join(' · ');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: DecoratedBox(
        key: const Key('playbackStatsOverlay'),
        decoration: BoxDecoration(
          color: const Color(0xcc000000),
          borderRadius: BorderRadius.circular(8),
        ),
        // The overlay ignores pointers and cannot scroll; shrink it to keep
        // every line visible in short windows and with large text.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: DefaultTextStyle(
              style: Theme.of(context).textTheme.bodySmall!.copyWith(
                color: Colors.white,
                height: 1.3,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${model.videoWidth} × ${model.videoHeight}'),
                  if (stats == null)
                    Text(strings.playbackStatsWaiting)
                  else ...[
                    Text('${stats.codec} · ${stats.decoder}'),
                    if (audio.isNotEmpty) Text(audio),
                    Text(
                      '${strings.playbackStatsFps} ${stats.fps.toStringAsFixed(1)}',
                    ),
                    Text(
                      '${strings.playbackStatsSubmitted} ${stats.submitted}',
                    ),
                    Text('${strings.playbackStatsDropped} ${stats.dropped}'),
                    Text('${strings.playbackStatsPending} ${stats.pending}'),
                    Text('${strings.playbackStatsQueued} ${stats.queued}'),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
