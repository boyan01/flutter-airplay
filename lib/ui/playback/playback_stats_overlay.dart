// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

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
                    Text(
                      [
                        stats.codec,
                        stats.videoDecoder,
                        stats.hardware
                            ? strings.playbackStatsHardware
                            : strings.playbackStatsSoftware,
                      ].where((part) => part.isNotEmpty).join(' · '),
                    ),
                    // lychee reports "none" without an audio track.
                    if (stats.audioDecoder.isNotEmpty &&
                        stats.audioDecoder != 'none')
                      Text(stats.audioDecoder),
                    Text(
                      '${strings.playbackStatsFps} ${stats.fps.toStringAsFixed(1)}',
                    ),
                    Text('${strings.playbackStatsDropped} ${stats.dropped}'),
                    Text(
                      '${strings.playbackStatsPacketsDropped} ${stats.packetsDropped}',
                    ),
                    Text(
                      strings.playbackStatsBuffered(
                        stats.videoBufferedMs,
                        stats.audioBufferedMs,
                      ),
                    ),
                    Text(
                      strings.playbackStatsAudioTiming(
                        stats.audioLateMs,
                        stats.audioSilenceMs,
                        stats.audioBehindMs,
                      ),
                    ),
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
