// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../receiver/receiver_model.dart';

/// Passive overlay; the shared playback worker supplies the measurements.
class PlaybackStatsOverlay extends StatelessWidget {
  const PlaybackStatsOverlay({super.key, required this.model});
  final ReceiverModel model;

  @override
  Widget build(BuildContext context) {
    final stats = model.playbackStats;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: DecoratedBox(
        key: const Key('playbackStatsOverlay'),
        decoration: BoxDecoration(
          color: const Color(0xcc000000),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: DefaultTextStyle(
            style: Theme.of(context).textTheme.bodySmall!
                .copyWith(color: Colors.white, fontSize: 11, height: 1.3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${model.videoWidth} × ${model.videoHeight}'),
                if (stats == null)
                  const Text('Waiting…')
                else ...[
                  Text('${stats.codec} · ${stats.decoder}'),
                  Text(
                    '${stats.audioCodec.isEmpty ? '-' : stats.audioCodec} · '
                    '${stats.audioSampleRate > 0 ? '${(stats.audioSampleRate / 1000).toStringAsFixed(1)} kHz' : '-'} · '
                    '${stats.audioChannels > 0 ? '${stats.audioChannels} ch' : '-'}',
                  ),
                  Text('FPS ${stats.fps.toStringAsFixed(1)}'),
                  Text('V/A   Drop ${stats.dropped}/-'),
                  Wrap(
                    spacing: 8,
                    children: [
                      Text('Pending ${stats.pending}/-'),
                      Text('· Queue ${stats.queued}/-'),
                    ],
                  ),
                  const Text('Underrun -'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
