// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_airplay/receiver/receiver_repository.dart';
import 'package:flutter_airplay/receiver/native/receiver_codec.dart';

class FakeReceiver extends ReceiverRepository {
  FakeReceiver({
    this.autoStart = true,
    this.enableVideoQuality = false,
    this.videoQualities = const ['auto', '720', '1080'],
    this.buildTime,
    this.buildVersion,
    this.capabilities = const {
      'platform': 'macos',
      'supportsExecutablePath': true,
    },
  });
  bool autoStart;
  final bool enableVideoQuality;
  final List<String> videoQualities;
  final String? buildTime, buildVersion;
  final Map<String, dynamic>? capabilities;
  final controller = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  int starts = 0, stops = 0;
  String currentStatus = 'stopped';
  Map<String, dynamic> activeSettings = {};
  bool connectBeforeApply = false;
  bool completesBeforeReady = false;
  @override
  Future<bool> applySettings() async {
    if (connectBeforeApply) state('streaming');
    if (currentStatus != 'waiting') return false;
    await stop();
    await start(savedName ?? startedName!, '');
    return true;
  }

  String? startedName, savedName, failure;
  String? savedVideoQuality, savedAudioOutput;
  bool savedFastPairing = false, savedShowPlaybackStats = false;
  int savedPlaybackBufferMs = 0;
  final fastPairingCalls = <bool?>[];
  Map<String, bool> savedOptions = {};
  String? saveFailure;
  Completer<void>? saving;
  int saves = 0;
  Completer<void>? startup;
  Completer<void>? shutdown;
  @override
  Stream<ReceiverEvent> get events =>
      controller.stream.map(decodeReceiverEvent);
  @override
  Future<ReceiverState> snapshot() async =>
      decodeReceiverState(await rawSnapshot());
  Future<Map<String, dynamic>> rawSnapshot() async => {
    'autoStart': autoStart,
    'fastPairing': savedFastPairing,
    'showPlaybackStats': savedShowPlaybackStats,
    'playbackBufferMs': savedPlaybackBufferMs,
    'status': currentStatus,
    'defaultName': 'System Device',
    'activeSettings': activeSettings,
    'receivingName': startedName ?? '',
    'message': '接收器未启动',
    'pid': 0,
    'name': savedName ?? 'Flutter AirPlay',
    'path': '',
    'logs': <dynamic>[],
    ...savedOptions,
    if (capabilities?['platform'] == 'android' || enableVideoQuality) ...{
      'videoQuality': savedVideoQuality ?? 'auto',
      'audioOutput': savedAudioOutput ?? 'auto',
      'buildTime': '2026-10-04T13:00:00Z',
      'buildVersion': '1.0.0 (1)',
      'videoQualities': videoQualities,
      'screenWidth': 1200,
      'screenHeight': 2670,
    },
    if (buildTime != null) 'buildTime': buildTime,
    if (buildVersion != null) 'buildVersion': buildVersion,
    if (capabilities != null) 'capabilities': capabilities,
  };
  bool _applying = false;
  void _scheduleApply() {
    if (_applying || currentStatus != 'waiting' || activeSettings.isEmpty) {
      return;
    }
    final desired = ReceiverSettings.fromJson({
      'name': savedName ?? startedName ?? 'Flutter AirPlay',
      'fastPairing': savedFastPairing,
      'showPlaybackStats': savedShowPlaybackStats,
      'playbackBufferMs': savedPlaybackBufferMs,
      'videoQuality': savedVideoQuality ?? 'auto',
      'audioOutput': savedAudioOutput ?? 'auto',
    });
    if (ReceiverSettings.fromJson(activeSettings).matchesRuntime(
      desired,
      videoQualitySupported:
          enableVideoQuality || capabilities?['platform'] == 'android',
      androidAudio: capabilities?['platform'] == 'android',
    )) {
      return;
    }
    _applying = true;
    scheduleMicrotask(() async {
      try {
        await applySettings();
        controller.add({'type': 'snapshot', 'data': await rawSnapshot()});
      } catch (error, stack) {
        controller.addError(error, stack);
      } finally {
        _applying = false;
      }
    });
  }

  void state(String status, [int pid = 42]) {
    currentStatus = status;
    controller.add({
      'type': 'state',
      'status': status,
      'message': status,
      'pid': pid,
    });
    _scheduleApply();
  }

  @override
  Future<void> start(String name, String path) async {
    starts++;
    startedName = name;
    activeSettings = {
      'name': name,
      'path': path,
      'fastPairing': savedFastPairing,
      'showPlaybackStats': savedShowPlaybackStats,
      'playbackBufferMs': savedPlaybackBufferMs,
      if (capabilities?['platform'] == 'android' || enableVideoQuality)
        'videoQuality': savedVideoQuality ?? 'auto',
      if (capabilities?['platform'] == 'android')
        'audioOutput': savedAudioOutput ?? 'auto',
    };
    if (failure != null) {
      state('error');
      throw PlatformException(code: 'receiver_error', message: failure);
    }
    state('starting');
    if (startup != null) {
      if (completesBeforeReady) {
        unawaited(startup!.future.then((_) => state('waiting')));
        return;
      }
      await startup!.future;
    }
    state('waiting');
  }

  @override
  Future<void> stop() async {
    stops++;
    if (shutdown != null) {
      state('stopping');
      await shutdown!.future;
    }
    state('stopped', 0);
  }

  @override
  Future<void> save(
    String name,
    String path, {
    bool autoStart = true,
    String? videoQuality,
    String? audioOutput,
    bool? fastPairing,
    bool? showPlaybackStats,
    int? playbackBufferMs,
    Map<String, bool> desktopOptions = const {},
  }) async {
    saves++;
    fastPairingCalls.add(fastPairing);
    if (saving != null) await saving!.future;
    if (saveFailure != null) {
      throw PlatformException(code: 'receiver_error', message: saveFailure);
    }
    this.autoStart = autoStart;
    if (showPlaybackStats != null) savedShowPlaybackStats = showPlaybackStats;
    if (playbackBufferMs != null) savedPlaybackBufferMs = playbackBufferMs;
    if (fastPairing != null) savedFastPairing = fastPairing;
    savedName = name;
    savedVideoQuality = videoQuality;
    savedAudioOutput = audioOutput;
    savedOptions = Map.of(desktopOptions);
    _scheduleApply();
  }

  @override
  Future<void> check(String path) async {
    if (failure != null) {
      throw PlatformException(code: 'receiver_error', message: failure);
    }
  }
}

void frame(FakeReceiver backend, [int width = 160, int height = 90]) {
  backend.state('streaming');
  backend.controller.add({
    'type': 'video',
    'textureId': 0,
    'videoWidth': width,
    'videoHeight': height,
  });
}

void media(FakeReceiver backend, {bool audio = true, bool paused = false}) {
  backend.state('streaming');
  backend.controller.add({
    'type': 'media',
    'audioPlaying': audio,
    'videoPaused': paused,
  });
  backend.controller.add({
    'type': 'video',
    'textureId': 0,
    'videoWidth': 0,
    'videoHeight': 0,
  });
}
