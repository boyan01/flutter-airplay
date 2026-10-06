// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:json_annotation/json_annotation.dart';

import 'receiver_settings.dart';
export 'receiver_settings.dart';

part 'receiver_state.g.dart';

enum ReceiverStatus {
  stopped,
  checking,
  starting,
  waiting,
  streaming,
  stopping,
  error,
}

enum ReceiverEventType {
  snapshot,
  state,
  client,
  video,
  media,
  log,
  playbackStats,
  unknown,
}

@JsonSerializable(createToJson: false)
class ReceiverLog {
  const ReceiverLog({required this.id, required this.time, required this.text});
  factory ReceiverLog.fromJson(Map<String, dynamic> json) =>
      _$ReceiverLogFromJson(json);

  final int id;
  final String time, text;
  String get display =>
      '${time.length >= 19 ? time.substring(11, 19) : time}  $text';
}

@JsonSerializable(createToJson: false)
class ReceiverCapabilities {
  const ReceiverCapabilities({
    this.platform = '',
    this.supportsExecutablePath = false,
    this.supportsLaunchAtLogin = false,
    this.supportsAacEld = false,
    this.isTelevision = false,
    this.nativeVideoSurface = false,
    this.foregroundOnly = false,
  });
  factory ReceiverCapabilities.fromJson(Map<String, dynamic> json) =>
      _$ReceiverCapabilitiesFromJson(json);

  final String platform;
  final bool supportsExecutablePath;
  final bool supportsLaunchAtLogin;
  final bool supportsAacEld;
  final bool isTelevision;
  final bool nativeVideoSurface;
  final bool foregroundOnly;
}

@JsonSerializable(createToJson: false)
class ReceiverState {
  const ReceiverState({
    this.settings = const ReceiverSettings(),
    this.activeSettings,
    this.capabilities = const ReceiverCapabilities(),
    this.status = ReceiverStatus.stopped,
    this.message = '',
    this.defaultName = 'Flutter AirPlay',
    this.receivingName = '',
    this.clientName = '',
    this.buildTime = '',
    this.buildVersion = '',
    this.videoQualities = const [],
    this.pid = 0,
    this.textureId = -1,
    this.screenWidth = 0,
    this.screenHeight = 0,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.generation = 0,
    this.audioPlaying = false,
    this.videoPaused = false,
    this.logs = const [],
  });
  factory ReceiverState.fromJson(Map<String, dynamic> json) =>
      _$ReceiverStateFromJson(json);

  ReceiverState copyWith({String? buildVersion}) => ReceiverState(
    settings: settings,
    activeSettings: activeSettings,
    capabilities: capabilities,
    status: status,
    message: message,
    defaultName: defaultName,
    receivingName: receivingName,
    clientName: clientName,
    buildTime: buildTime,
    buildVersion: buildVersion ?? this.buildVersion,
    videoQualities: videoQualities,
    pid: pid,
    textureId: textureId,
    screenWidth: screenWidth,
    screenHeight: screenHeight,
    videoWidth: videoWidth,
    videoHeight: videoHeight,
    generation: generation,
    audioPlaying: audioPlaying,
    videoPaused: videoPaused,
    logs: logs,
  );

  final ReceiverSettings settings;
  final ReceiverSettings? activeSettings;
  final ReceiverCapabilities capabilities;
  final ReceiverStatus status;
  final String message;
  final String defaultName;
  final String receivingName;
  final String clientName;
  final String buildTime;
  final String buildVersion;
  final List<String> videoQualities;
  final int pid;
  final int textureId;
  final int screenWidth;
  final int screenHeight;
  final int videoWidth;
  final int videoHeight;
  final int generation;
  final bool audioPlaying;
  final bool videoPaused;
  final List<ReceiverLog> logs;
}

@JsonSerializable(createToJson: false)
class ReceiverEvent {
  const ReceiverEvent({
    this.type = ReceiverEventType.unknown,
    this.snapshot,
    this.status = ReceiverStatus.stopped,
    this.message = '',
    this.name = '',
    this.pid = 0,
    this.textureId = -1,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.audioPlaying = false,
    this.videoPaused = false,
    this.log,
    this.playbackStats,
  });
  factory ReceiverEvent.fromJson(Map<String, dynamic> json) =>
      _$ReceiverEventFromJson(json);

  @JsonKey(unknownEnumValue: ReceiverEventType.unknown)
  final ReceiverEventType type;
  @JsonKey(name: 'data')
  final ReceiverState? snapshot;
  final ReceiverStatus status;
  final String message;
  final String name;
  final int pid;
  final int textureId;
  final int videoWidth;
  final int videoHeight;
  final bool audioPlaying;
  final bool videoPaused;
  @JsonKey(name: 'entry')
  final ReceiverLog? log;
  @JsonKey(name: 'metrics')
  final PlaybackStats? playbackStats;
}

/// Scheduler submissions are not measured screen presentations or network losses.
@JsonSerializable(createToJson: false)
class PlaybackStats {
  const PlaybackStats({
    this.audioCodec = '',
    this.audioSampleRate = 0,
    this.audioChannels = 0,
    this.codec = '',
    this.decoder = '',
    this.fps = 0,
    this.submitted = 0,
    this.dropped = 0,
    this.pending = 0,
    this.queued = 0,
  });
  factory PlaybackStats.fromJson(Map<String, dynamic> json) =>
      _$PlaybackStatsFromJson(json);
  final String audioCodec;
  final int audioSampleRate, audioChannels;
  final String codec, decoder;
  final double fps;
  final int submitted, dropped, pending, queued;
}
