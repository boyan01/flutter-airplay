// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'receiver_settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ReceiverSettings _$ReceiverSettingsFromJson(Map<String, dynamic> json) =>
    ReceiverSettings(
      name: json['name'] as String? ?? 'Flutter AirPlay',
      path: json['path'] as String? ?? '',
      autoStart: json['autoStart'] as bool? ?? true,
      fastPairing: json['fastPairing'] as bool? ?? false,
      videoQuality:
          $enumDecodeNullable(_$VideoQualityEnumMap, json['videoQuality']) ??
          VideoQuality.auto,
      audioOutput:
          $enumDecodeNullable(_$AudioOutputEnumMap, json['audioOutput']) ??
          AudioOutput.auto,
      launchAtLogin: json['launchAtLogin'] as bool? ?? false,
      keepInMenuBar: json['keepInMenuBar'] as bool? ?? true,
      showOnConnect: json['showOnConnect'] as bool? ?? true,
      fullscreenOnConnect: json['fullscreenOnConnect'] as bool? ?? false,
      alwaysOnTop: json['alwaysOnTop'] as bool? ?? false,
    );

Map<String, dynamic> _$ReceiverSettingsToJson(ReceiverSettings instance) =>
    <String, dynamic>{
      'name': instance.name,
      'path': instance.path,
      'autoStart': instance.autoStart,
      'fastPairing': instance.fastPairing,
      'videoQuality': _$VideoQualityEnumMap[instance.videoQuality]!,
      'audioOutput': _$AudioOutputEnumMap[instance.audioOutput]!,
      'launchAtLogin': instance.launchAtLogin,
      'keepInMenuBar': instance.keepInMenuBar,
      'showOnConnect': instance.showOnConnect,
      'fullscreenOnConnect': instance.fullscreenOnConnect,
      'alwaysOnTop': instance.alwaysOnTop,
    };

const _$VideoQualityEnumMap = {
  VideoQuality.auto: 'auto',
  VideoQuality.p720: '720',
  VideoQuality.p1080: '1080',
  VideoQuality.p1440: '1440',
  VideoQuality.p2160: '2160',
};

const _$AudioOutputEnumMap = {
  AudioOutput.auto: 'auto',
  AudioOutput.aaudio: 'aaudio',
  AudioOutput.audiotrack: 'audiotrack',
};
