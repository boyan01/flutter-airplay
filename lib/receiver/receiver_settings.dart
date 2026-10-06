// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:json_annotation/json_annotation.dart';

part 'receiver_settings.g.dart';

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
  const ReceiverSettings({
    this.name = 'Flutter AirPlay',
    this.path = '',
    this.autoStart = true,
    this.fastPairing = true,
    this.showPlaybackStats = false,
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
      (!videoQualitySupported || videoQuality == other.videoQuality) &&
      (!androidAudio || audioOutput == other.audioOutput);
}
