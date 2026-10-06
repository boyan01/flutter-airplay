// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

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
        return Map.of(data);
      case 'save':
        if (args['videoQuality'] == 'invalid') {
          throw StateError('Unknown video quality');
        }
        data = {...data, ...args, 'name': (args['name'] as String).trim()};
      case 'applySettings':
        return {'applied': false};
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
    });
    final data = await repository(control('macos')).snapshot();
    expect(data.settings.name, 'Saved in Dart');
    expect(data.settings.videoQuality, VideoQuality.p720);
    expect(data.settings.fastPairing, false);
    expect(data.settings.showPlaybackStats, true);
  });
  test(
    'serialized saves preserve options and canonical native values',
    () async {
      final native = control('linux');
      final repo = repository(native);
      await repo.snapshot();
      await Future.wait([
        repo.save('  Updated  ', '', fastPairing: false),
        repo.save('Last', '', videoQuality: '1080'),
      ]);
      final data = jsonDecode(preferences.value!);
      expect(data['name'], 'Last');
      expect(data['videoQuality'], '1080');
      expect(data['fastPairing'], false);
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
