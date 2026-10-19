// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_airplay/receiver/receiver_settings_store.dart';

import 'package:flutter_airplay/receiver/native/receiver_control.dart';
import 'package:flutter_airplay/receiver/receiver_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

class TestControl implements ReceiverControl {
  TestControl(this.data);
  Map<String, dynamic> data;
  final stream = StreamController<Map<String, dynamic>>.broadcast();
  final commands = <String>[];
  // Holds the next snapshot reply, taken when it was requested.
  Completer<void>? snapshotGate;
  bool closed = false;
  @override
  Stream<Map<String, dynamic>> get events => stream.stream;
  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    commands.add(method);
    switch (method) {
      case 'snapshot':
        final snapshot = Map.of(data);
        final gate = snapshotGate;
        snapshotGate = null;
        await gate?.future;
        return snapshot;
      case 'save':
        if (args['videoQuality'] == 'invalid') {
          throw StateError('Unknown video quality');
        }
        if (args['playbackBufferMs'] == -1) {
          throw StateError('Unsupported playback buffer');
        }
        data = {...data, ...args, 'name': (args['name'] as String).trim()};
      case 'applySettings':
        return {'applied': false};
      case 'restoreVolume':
        if (data['status'] == 'stopped') data['volumeDb'] = args['volumeDb'];
    }
    return {};
  }

  @override
  void dispose() {
    closed = true;
    unawaited(stream.close());
  }
}

class MemoryPreferences implements SharedPreferencesAsync {
  final _state = <String, Object?>{};
  String? get value => _state['value'] as String?;
  set value(String? value) => _state['value'] = value;
  bool get failWrites => _state['failWrites'] == true;
  set failWrites(bool value) => _state['failWrites'] = value;
  double? get volume => _state['volume'] as double?;
  set volume(double? value) => _state['volume'] = value;
  @override
  Future<double?> getDouble(String key) async {
    expect(key, ReceiverSettingsStore.volumeKey);
    return volume;
  }

  @override
  Future<void> setDouble(String key, double value) async {
    expect(key, ReceiverSettingsStore.volumeKey);
    if (failWrites) throw StateError('Synthetic persistence failure');
    volume = value;
  }

  @override
  Future<String?> getString(String key) async {
    expect(key, ReceiverSettingsStore.storageKey);
    return value;
  }

  @override
  Future<void> setString(String key, String value) async {
    expect(key, ReceiverSettingsStore.storageKey);
    if (failWrites) throw StateError('Synthetic persistence failure');
    this.value = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryPreferences preferences;
  final repositories = <NativeReceiverRepository>[];
  TestControl control(String platform) => TestControl({
    'status': 'stopped',
    'generation': 0,
    'buildTime': '2026-10-05T01:02:03Z',
    'capabilities': {'platform': platform},
    'name': 'Existing receiver',
    'path': '',
    'autoStart': false,
    'videoQuality': 'auto',
    'fastPairing': true,
  });
  NativeReceiverRepository repository(TestControl native) {
    final result = NativeReceiverRepository(
      settings: ReceiverSettingsStore(preferences),
      bootstrap: () async => {'handle': 42},
      connect: (handle) {
        expect(handle, 42);
        return native;
      },
    );
    repositories.add(result);
    return result;
  }

  setUp(() async {
    preferences = MemoryPreferences();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('org.airplayreceiver/platform'),
          (call) async {
            expect(call.method, 'prepareReception');
            return null;
          },
        );
    PackageInfo.setMockInitialValues(
      appName: 'Flutter AirPlay',
      packageName: 'tech.soit.flutterairplay',
      version: '2.3.4',
      buildNumber: '56',
      buildSignature: '',
    );
  });
  tearDown(() async {
    for (final value in repositories) {
      value.dispose();
    }
    repositories.clear();
  });
  for (final platform in ['macos', 'ios', 'android', 'linux', 'windows']) {
    test('$platform uses shared defaults and packaged version', () async {
      final native = control(platform);
      final data = await repository(native).snapshot();
      expect(data.buildVersion, '2.3.4 (56)');
      expect(data.buildTime, '2026-10-05T01:02:03Z');
      expect(data.settings.name, 'Existing receiver');
      expect(data.settings.autoStart, false);
      expect(data.settings.fastPairing, true);
      expect(data.settings.playbackBufferMs, 0);
      expect(preferences.value, isNull);
    });
  }
  test('Dart settings restore after reconnect', () async {
    preferences.value = jsonEncode({
      'name': 'Saved in Dart',
      'videoQuality': '720',
      'autoStart': false,
      'fastPairing': false,
      'showPlaybackStats': true,
      'playbackBufferMs': 100,
    });
    final data = await repository(control('macos')).snapshot();
    expect(data.settings.name, 'Saved in Dart');
    expect(data.settings.videoQuality, VideoQuality.p720);
    expect(data.settings.fastPairing, false);
    expect(data.settings.showPlaybackStats, true);
    expect(data.settings.playbackBufferMs, 100);
  });
  test('unreadable stored settings fall back to native defaults', () async {
    for (final stored in [
      '{not json',
      '[]',
      jsonEncode({'name': 'From newer version', 'videoQuality': '4320'}),
      jsonEncode({'name': 'Rejected by native', 'playbackBufferMs': -1}),
    ]) {
      preferences.value = stored;
      final native = control('macos');
      final repo = repository(native);
      final data = await repo.snapshot();
      expect(data.settings.name, 'Existing receiver', reason: stored);
      await repo.start('Started', '');
      expect(native.commands, contains('start'), reason: stored);
    }
  });
  for (final platform in ['macos', 'ios', 'android', 'linux', 'windows']) {
    test(
      '$platform persists sender volume and restores it before start',
      () async {
        final native = control(platform);
        final repo = repository(native);
        await repo.snapshot();
        expect(native.commands, isNot(contains('restoreVolume')));
        for (final db in [-7.5, -30.0, -144.0]) {
          native.stream.add({'type': 'volume', 'volumeDb': db});
        }
        await repo.save('Renamed', '', playbackBufferMs: 100);
        for (var i = 0; i < 100 && preferences.volume != -144; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(preferences.volume, -144);
        expect(jsonDecode(preferences.value!), isNot(contains('volumeDb')));
        final restarted = control(platform);
        await repository(restarted).start('Restarted', '');
        expect(restarted.data['volumeDb'], -144);
        expect(
          restarted.commands.indexOf('restoreVolume'),
          lessThan(restarted.commands.indexOf('start')),
        );
      },
    );
  }
  test('reattaching preserves current playback volume', () async {
    preferences.volume = -20;
    final native = control('macos');
    native.data.addAll({'status': 'streaming', 'volumeDb': -7.5});
    await repository(native).snapshot();
    expect(native.data['volumeDb'], -7.5);
  });
  test('invalid persisted volume falls back to native default', () async {
    for (final db in [double.nan, double.infinity, -31.0, 1.0]) {
      preferences.volume = db;
      final native = control('macos');
      await repository(native).snapshot();
      expect(native.commands, isNot(contains('restoreVolume')));
    }
  });
  test('volume persistence recovers after a failed write', () async {
    final native = control('macos');
    final repo = repository(native);
    await repo.snapshot();
    final error = expectLater(repo.events, emitsError(isStateError));
    preferences.failWrites = true;
    native.stream.add({'type': 'volume', 'volumeDb': -10.0});
    await error;
    preferences.failWrites = false;
    native.stream.add({'type': 'volume', 'volumeDb': -12.0});
    for (var i = 0; i < 100 && preferences.volume != -12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(preferences.volume, -12);
  });
  test(
    'serialized saves preserve options and canonical native values',
    () async {
      final native = control('linux');
      final repo = repository(native);
      await repo.snapshot();
      await Future.wait([
        repo.save('  Updated  ', '', fastPairing: false, playbackBufferMs: 200),
        repo.save('Last', '', videoQuality: '1080'),
      ]);
      final data = jsonDecode(preferences.value!);
      expect(data['name'], 'Last');
      expect(data['videoQuality'], '1080');
      expect(data['fastPairing'], false);
      expect(data['playbackBufferMs'], 200);
      await expectLater(
        repo.save('Rejected', '', videoQuality: 'invalid'),
        throwsStateError,
      );
      expect(jsonDecode(preferences.value!)['name'], 'Last');
      await repo.save('Recovered', '');
      expect(native.data['name'], 'Recovered');
    },
  );
  test(
    'persistence failure leaves runtime untouched and a later save recovers',
    () async {
      final native = control('windows');
      final repo = repository(native);
      await repo.snapshot();
      preferences.failWrites = true;
      await expectLater(
        repo.save('Unsaved', '', fastPairing: false),
        throwsStateError,
      );
      expect(native.data['name'], 'Existing receiver');
      expect(native.data['fastPairing'], true);
      expect(native.commands, isNot(contains('save')));
      preferences.failWrites = false;
      await repo.save('Recovered', '');
      expect(jsonDecode(preferences.value!)['name'], 'Recovered');
    },
  );
  test('native menu settings use the Dart writer', () async {
    final native = control('macos');
    final repo = repository(native);
    await repo.snapshot();
    native.stream.add({
      'type': 'settingsRequest',
      'settings': {'alwaysOnTop': true},
    });
    for (var i = 0; i < 100; i++) {
      final saved = jsonDecode(preferences.value ?? '{}');
      if (saved['alwaysOnTop'] == true) {
        expect(native.data['alwaysOnTop'], true);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Native settings request was not persisted');
  });
  test('desired settings persist before runtime changes and apply only after the session ends', () async {
    final native = control('macos');
    native.data['status'] = 'streaming';
    native.data['activeSettings'] = {
      'name': 'Existing receiver',
      'path': '',
      'fastPairing': true,
    };
    final repo = repository(native);
    await repo.snapshot();
    await repo.save('Pending receiver', '');
    await Future<void>.delayed(Duration.zero);
    expect(jsonDecode(preferences.value!)['name'], 'Pending receiver');
    expect(native.commands, isNot(contains('applySettings')));
    native.data['status'] = 'waiting';
    native.stream.add({'type': 'snapshot', 'data': native.data});
    for (
      var i = 0;
      i < 100 && !native.commands.contains('applySettings');
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      native.commands.where((command) => command == 'applySettings'),
      hasLength(1),
    );
  });

  test('a session ending during a settings check is checked again', () async {
    final native = control('macos');
    native.data['status'] = 'streaming';
    native.data['activeSettings'] = {
      'name': 'Existing receiver',
      'path': '',
      'fastPairing': true,
    };
    final repo = repository(native);
    await repo.snapshot();
    await repo.save('Pending receiver', '');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final gate = native.snapshotGate = Completer<void>();
    native.stream.add({'type': 'snapshot', 'data': native.data});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // The session ends after the running check read its snapshot.
    native.data['status'] = 'waiting';
    native.stream.add({'type': 'snapshot', 'data': native.data});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete();
    for (
      var i = 0;
      i < 100 && !native.commands.contains('applySettings');
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(native.commands, contains('applySettings'));
  });

  test(
    'reconnect applies restored desired settings to an idle runtime',
    () async {
      preferences.value = jsonEncode({'name': 'Restored receiver'});
      final native = control('macos');
      native.data['status'] = 'waiting';
      native.data['activeSettings'] = {
        'name': 'Existing receiver',
        'path': '',
        'fastPairing': true,
      };
      final repo = repository(native);
      await repo.snapshot();
      for (
        var i = 0;
        i < 100 && !native.commands.contains('applySettings');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(native.data['name'], 'Restored receiver');
      expect(native.commands, contains('applySettings'));
    },
  );

  test('dispose releases the native subscription', () async {
    final native = control('macos');
    final repo = repository(native);
    await repo.snapshot();
    repo.dispose();
    expect(native.closed, true);
  });
}
