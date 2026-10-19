// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';

part 'receiver_settings.g.dart';

/// The native receiver's name rule: 1-50 UTF-8 bytes after trimming, without
/// C0 or C1 control characters. Returns an l10n message key.
String? receiverNameError(String value) {
  final name = value.trim();
  if (name.isEmpty) return 'nameRequired';
  if (utf8.encode(name).length > 50 ||
      name.runes.any((rune) => rune < 32 || (rune >= 127 && rune <= 159))) {
    return 'nameInvalid';
  }
  return null;
}

@JsonEnum(valueField: 'value')
enum VideoQuality {
  auto('auto'),
  p720('720'),
  p1080('1080'),
  p1440('1440'),
  p2160('2160');

  const VideoQuality(this.value);
  final String value;
}

enum AudioOutput { auto, aaudio, audiotrack }

/// Desired values. Persistence and native conversion belong to their adapters.
@JsonSerializable()
class ReceiverSettings {
  static const playbackBufferOptions = [0, 40, 60, 80, 100, 120, 150, 200, 300];
  const ReceiverSettings({
    this.name = 'Flutter AirPlay',
    this.path = '',
    this.autoStart = true,
    this.fastPairing = true,
    this.showPlaybackStats = false,
    this.playbackBufferMs = 0,
    this.videoQuality = VideoQuality.auto,
    this.audioOutput = AudioOutput.auto,
    this.launchAtLogin = false,
    this.keepInMenuBar = true,
    this.showOnConnect = true,
    this.fullscreenOnConnect = false,
    this.alwaysOnTop = false,
  });
  factory ReceiverSettings.fromJson(Map<String, dynamic> json) =>
      _$ReceiverSettingsFromJson(json);
  Map<String, dynamic> toJson() => _$ReceiverSettingsToJson(this);

  final String name;
  final String path;
  final bool autoStart;
  final bool fastPairing;
  final bool showPlaybackStats;
  // Zero preserves the native platform default.
  final int playbackBufferMs;
  final VideoQuality videoQuality;
  final AudioOutput audioOutput;
  final bool launchAtLogin;
  final bool keepInMenuBar;
  final bool showOnConnect;
  final bool fullscreenOnConnect;
  final bool alwaysOnTop;

  @JsonKey(includeFromJson: false, includeToJson: false)
  Map<String, bool> get desktopOptions => {
    'launchAtLogin': launchAtLogin,
    'keepInMenuBar': keepInMenuBar,
    'showOnConnect': showOnConnect,
    'fullscreenOnConnect': fullscreenOnConnect,
    'alwaysOnTop': alwaysOnTop,
  };
  bool matchesRuntime(
    ReceiverSettings other, {
    required bool videoQualitySupported,
    required bool androidAudio,
  }) =>
      name == other.name &&
      path == other.path &&
      fastPairing == other.fastPairing &&
      playbackBufferMs == other.playbackBufferMs &&
      (!videoQualitySupported || videoQuality == other.videoQuality) &&
      (!androidAudio || audioOutput == other.audioOutput);
}
