import 'dart:convert';

import 'package:flutter_airplay/receiver/native/receiver_codec.dart';
import 'package:flutter_airplay/receiver/receiver_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('JSON completion handles numeric request IDs, results and errors', () {
    final success = ReceiverReply.fromJson({
      'request': 2.0,
      'data': {'applied': false},
    });
    expect(success.request, 2);
    expect(success.data['applied'], isFalse);
    expect(success.error, isNull);
    final failure = ReceiverReply.fromJson({
      'request': 3,
      'error': 'Unknown receiver command',
    });
    expect(failure.request, 3);
    expect(failure.error, 'Unknown receiver command');
    expect(failure.data, isEmpty);
  });

  test(
    'settings JSON preserves enum wire values and excludes derived fields',
    () {
      const settings = ReceiverSettings(
        name: 'Xiaomi 14',
        videoQuality: VideoQuality.p1080,
        audioOutput: AudioOutput.aaudio,
        fastPairing: true,
      );
      final json = settings.toJson();
      expect(json['videoQuality'], '1080');
      expect(json['audioOutput'], 'aaudio');
      expect(json.containsKey('desktopOptions'), isFalse);
      expect(ReceiverSettings.fromJson(json).toJson(), json);
    },
  );

  test('native snapshot retains flat settings and absent active session', () {
    final state = decodeReceiverState({
      'name': 'Xiaomi 14',
      'videoQuality': '720',
      'activeSettings': <String, dynamic>{},
      'capabilities': {'platform': 'android', 'nativeVideoSurface': true},
    });
    expect(state.settings.name, 'Xiaomi 14');
    expect(state.settings.videoQuality, VideoQuality.p720);
    expect(state.activeSettings, isNull);
    expect(state.capabilities.platform, 'android');
    expect(state.capabilities.nativeVideoSurface, isTrue);
    expect(state.textureId, -1);
    expect(state.status, ReceiverStatus.stopped);
    expect(
      decodeReceiverEvent({'type': 'futureEvent'}).type,
      ReceiverEventType.unknown,
    );
    expect(
      () => ReceiverSettings.fromJson({'videoQuality': 'invalid'}),
      throwsArgumentError,
    );
  });

  test('native JSON numeric values decode into integer state and events', () {
    final data = jsonDecode('''{
      "type": "snapshot",
      "data": {"textureId": 4.0, "pid": 12.0, "screenWidth": 1920.0,
        "screenHeight": 1080.0, "videoWidth": 1280.0, "videoHeight": 720.0,
        "generation": 2.0,
        "logs": [{"id": 3.0, "level": "info", "time": "", "text": "ready"}]},
      "textureId": 4.0, "pid": 12.0, "videoWidth": 1280.0, "videoHeight": 720.0
    }''') as Map<String, dynamic>;
    final event = decodeReceiverEvent(data);
    final state = event.snapshot!;
    expect(state.textureId, 4);
    expect(state.pid, 12);
    expect(state.screenWidth, 1920);
    expect(state.screenHeight, 1080);
    expect(state.videoWidth, 1280);
    expect(state.videoHeight, 720);
    expect(state.generation, 2);
    expect(state.logs.single.id, 3);
    expect(event.textureId, 4);
    expect(event.pid, 12);
    expect(event.videoWidth, 1280);
    expect(event.videoHeight, 720);
  });
}
