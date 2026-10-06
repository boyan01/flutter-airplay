// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:mixin_logger/mixin_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Directory? loggingDirectory;

// Engine timings describe Flutter composition, not which video frame reached
// the monitor. Pair these with native submit and texture acquisition statistics.
class FlutterFrameDiagnostics {
  FlutterFrameDiagnostics({
    required this.isPlaying,
    required this.refreshRate,
  }) {
    if (!kReleaseMode) SchedulerBinding.instance.addTimingsCallback(_record);
  }

  final bool Function() isPlaying;
  final double Function() refreshRate;
  final _clock = Stopwatch()..start();
  int _started = 0, _frames = 0, _lastRaster = 0;
  int _buildTotal = 0, _rasterTotal = 0;
  int _buildMax = 0, _rasterMax = 0, _spanMax = 0, _gapMax = 0;
  int _buildOver = 0, _rasterOver = 0, _spanOver = 0;
  int _rasterPeakUtcMs = 0, _spanPeakUtcMs = 0, _gapPeakUtcMs = 0;
  int _lastFrameNumber = -1, _unreportedFrames = 0, _deliveryMax = 0;

  void _record(List<FrameTiming> timings) {
    if (!isPlaying()) {
      _reset();
      _started = _lastRaster = 0;
      _lastFrameNumber = -1;
      return;
    }
    final hz = refreshRate();
    final budget = 1000000 / (hz > 0 ? hz : 60);
    if (_started == 0) _started = _clock.elapsedMicroseconds;
    for (final timing in timings) {
      final build = timing.buildDuration.inMicroseconds;
      final raster = timing.rasterDuration.inMicroseconds;
      final span = timing.totalSpan.inMicroseconds;
      final finish = timing.timestampInMicroseconds(FramePhase.rasterFinish);
      final wallMs =
          timing.timestampInMicroseconds(FramePhase.rasterFinishWallTime) ~/
          1000;
      final delivery = DateTime.now().millisecondsSinceEpoch - wallMs;
      if (delivery > _deliveryMax) _deliveryMax = delivery;
      if (_lastFrameNumber >= 0 && timing.frameNumber > _lastFrameNumber + 1) {
        _unreportedFrames += timing.frameNumber - _lastFrameNumber - 1;
      }
      _lastFrameNumber = timing.frameNumber;
      ++_frames;
      _buildTotal += build;
      _rasterTotal += raster;
      if (build > _buildMax) _buildMax = build;
      if (raster > _rasterMax) {
        _rasterMax = raster;
        _rasterPeakUtcMs = wallMs;
      }
      if (span > _spanMax) {
        _spanMax = span;
        _spanPeakUtcMs = wallMs;
      }
      if (_lastRaster != 0 && finish - _lastRaster > _gapMax) {
        _gapMax = finish - _lastRaster;
        _gapPeakUtcMs = wallMs;
      }
      _lastRaster = finish;
      if (build > budget) ++_buildOver;
      if (raster > budget) ++_rasterOver;
      if (span > budget) ++_spanOver;
    }
    final interval = _clock.elapsedMicroseconds - _started;
    if (interval < 5000000 || _frames == 0) return;
    String ms(num value) => (value / 1000).toStringAsFixed(3);
    i(
      'Flutter frame stats: interval_ms=${ms(interval)} frames=$_frames '
      'refresh_hz=${hz.toStringAsFixed(2)} budget_ms=${ms(budget)} '
      'build_avg_ms=${ms(_buildTotal / _frames)} build_max_ms=${ms(_buildMax)} '
      'raster_avg_ms=${ms(_rasterTotal / _frames)} raster_max_ms=${ms(_rasterMax)} '
      'span_max_ms=${ms(_spanMax)} reported_raster_gap_max_ms=${ms(_gapMax)} '
      'unreported_frame_numbers=$_unreportedFrames delivery_max_ms=$_deliveryMax '
      'build_over_budget=$_buildOver raster_over_budget=$_rasterOver '
      'span_over_budget=$_spanOver raster_peak_utc_ms=$_rasterPeakUtcMs '
      'span_peak_utc_ms=$_spanPeakUtcMs gap_peak_utc_ms=$_gapPeakUtcMs',
    );
    _reset();
    _started = _clock.elapsedMicroseconds;
  }

  void _reset() {
    _frames = _buildTotal = _rasterTotal = 0;
    _buildMax = _rasterMax = _spanMax = _gapMax = 0;
    _buildOver = _rasterOver = _spanOver = 0;
    _rasterPeakUtcMs = _spanPeakUtcMs = _gapPeakUtcMs = 0;
    _unreportedFrames = _deliveryMax = 0;
  }

  void dispose() {
    if (!kReleaseMode) SchedulerBinding.instance.removeTimingsCallback(_record);
    _clock.stop();
  }
}

Future<void> initializeLogging() async {
  final directory = Platform.isAndroid
      ? await getExternalStorageDirectory() ??
            await getApplicationSupportDirectory()
      : await getApplicationSupportDirectory();
  final path = p.join(directory.path, 'logs');
  loggingDirectory = Directory(path);
  initLogger(path, maxFileCount: 10, maxFileLength: 5 * 1024 * 1024);
  i(
    'Flutter AirPlay started: platform=${Platform.operatingSystem}, '
    'mode=${kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug'}, '
    'logs=$path',
  );
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) i('[Flutter] $message');
  };
  FlutterError.onError = (details) {
    e('Flutter framework error', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    e('Uncaught platform error', error, stack);
    return true;
  };
}
