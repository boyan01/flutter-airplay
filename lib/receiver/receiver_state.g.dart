// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'receiver_state.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ReceiverLog _$ReceiverLogFromJson(Map<String, dynamic> json) => ReceiverLog(
  id: (json['id'] as num).toInt(),
  time: json['time'] as String,
  text: json['text'] as String,
);

ReceiverCapabilities _$ReceiverCapabilitiesFromJson(
  Map<String, dynamic> json,
) => ReceiverCapabilities(
  platform: json['platform'] as String? ?? '',
  supportsExecutablePath: json['supportsExecutablePath'] as bool? ?? false,
  supportsLaunchAtLogin: json['supportsLaunchAtLogin'] as bool? ?? false,
  supportsAacEld: json['supportsAacEld'] as bool? ?? false,
  isTelevision: json['isTelevision'] as bool? ?? false,
  nativeVideoSurface: json['nativeVideoSurface'] as bool? ?? false,
  foregroundOnly: json['foregroundOnly'] as bool? ?? false,
);

ReceiverState _$ReceiverStateFromJson(Map<String, dynamic> json) =>
    ReceiverState(
      settings: json['settings'] == null
          ? const ReceiverSettings()
          : ReceiverSettings.fromJson(json['settings'] as Map<String, dynamic>),
      activeSettings: json['activeSettings'] == null
          ? null
          : ReceiverSettings.fromJson(
              json['activeSettings'] as Map<String, dynamic>,
            ),
      capabilities: json['capabilities'] == null
          ? const ReceiverCapabilities()
          : ReceiverCapabilities.fromJson(
              json['capabilities'] as Map<String, dynamic>,
            ),
      status:
          $enumDecodeNullable(_$ReceiverStatusEnumMap, json['status']) ??
          ReceiverStatus.stopped,
      message: json['message'] as String? ?? '',
      defaultName: json['defaultName'] as String? ?? 'Flutter AirPlay',
      receivingName: json['receivingName'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      buildTime: json['buildTime'] as String? ?? '',
      buildVersion: json['buildVersion'] as String? ?? '',
      videoQualities:
          (json['videoQualities'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      pid: (json['pid'] as num?)?.toInt() ?? 0,
      textureId: (json['textureId'] as num?)?.toInt() ?? -1,
      screenWidth: (json['screenWidth'] as num?)?.toInt() ?? 0,
      screenHeight: (json['screenHeight'] as num?)?.toInt() ?? 0,
      videoWidth: (json['videoWidth'] as num?)?.toInt() ?? 0,
      videoHeight: (json['videoHeight'] as num?)?.toInt() ?? 0,
      generation: (json['generation'] as num?)?.toInt() ?? 0,
      audioPlaying: json['audioPlaying'] as bool? ?? false,
      videoPaused: json['videoPaused'] as bool? ?? false,
      logs:
          (json['logs'] as List<dynamic>?)
              ?.map((e) => ReceiverLog.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

const _$ReceiverStatusEnumMap = {
  ReceiverStatus.stopped: 'stopped',
  ReceiverStatus.checking: 'checking',
  ReceiverStatus.starting: 'starting',
  ReceiverStatus.waiting: 'waiting',
  ReceiverStatus.streaming: 'streaming',
  ReceiverStatus.stopping: 'stopping',
  ReceiverStatus.error: 'error',
};

ReceiverEvent _$ReceiverEventFromJson(Map<String, dynamic> json) =>
    ReceiverEvent(
      type:
          $enumDecodeNullable(
            _$ReceiverEventTypeEnumMap,
            json['type'],
            unknownValue: ReceiverEventType.unknown,
          ) ??
          ReceiverEventType.unknown,
      snapshot: json['data'] == null
          ? null
          : ReceiverState.fromJson(json['data'] as Map<String, dynamic>),
      status:
          $enumDecodeNullable(_$ReceiverStatusEnumMap, json['status']) ??
          ReceiverStatus.stopped,
      message: json['message'] as String? ?? '',
      name: json['name'] as String? ?? '',
      pid: (json['pid'] as num?)?.toInt() ?? 0,
      textureId: (json['textureId'] as num?)?.toInt() ?? -1,
      videoWidth: (json['videoWidth'] as num?)?.toInt() ?? 0,
      videoHeight: (json['videoHeight'] as num?)?.toInt() ?? 0,
      audioPlaying: json['audioPlaying'] as bool? ?? false,
      videoPaused: json['videoPaused'] as bool? ?? false,
      log: json['entry'] == null
          ? null
          : ReceiverLog.fromJson(json['entry'] as Map<String, dynamic>),
      playbackStats: json['metrics'] == null
          ? null
          : PlaybackStats.fromJson(json['metrics'] as Map<String, dynamic>),
    );

const _$ReceiverEventTypeEnumMap = {
  ReceiverEventType.snapshot: 'snapshot',
  ReceiverEventType.state: 'state',
  ReceiverEventType.client: 'client',
  ReceiverEventType.video: 'video',
  ReceiverEventType.media: 'media',
  ReceiverEventType.log: 'log',
  ReceiverEventType.playbackStats: 'playbackStats',
  ReceiverEventType.unknown: 'unknown',
};

PlaybackStats _$PlaybackStatsFromJson(Map<String, dynamic> json) =>
    PlaybackStats(
      codec: json['codec'] as String? ?? '',
      decoder: json['decoder'] as String? ?? '',
      fps: (json['fps'] as num?)?.toDouble() ?? 0,
      submitted: (json['submitted'] as num?)?.toInt() ?? 0,
      dropped: (json['dropped'] as num?)?.toInt() ?? 0,
      pending: (json['pending'] as num?)?.toInt() ?? 0,
      queued: (json['queued'] as num?)?.toInt() ?? 0,
    );
