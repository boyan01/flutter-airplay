import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_airplay/platform/app_updates.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> snapshot(
  String status, {
  String? version,
  String? error,
}) => {
  'enabled': true,
  'status': status,
  'version': version,
  'error': error,
  'capabilities': {
    'checkForUpdates': status != 'checking',
    'showUpdate': version != null,
  },
};

class MemoryPreferences extends AppUpdatePreferences {
  bool automatic = true;
  bool failWrite = false;
  DateTime? checked;
  @override
  Future<bool> readAutomaticallyCheck() async => automatic;
  @override
  Future<void> writeAutomaticallyCheck(bool value) async {
    if (failWrite) throw StateError('Cannot save');
    automatic = value;
  }

  @override
  Future<DateTime?> readLastChecked() async => checked;
  @override
  Future<void> writeLastChecked(DateTime value) async => checked = value;
}

class FakeUpdateService extends AppUpdateService {
  ValueChanged<Map<String, dynamic>>? listener;
  int checks = 0, presentations = 0, initializations = 0;
  int installs = 0, cancellations = 0;
  Completer<Map<String, dynamic>>? pendingInstall;
  @override
  Future<Map<String, dynamic>> installUpdate() async {
    installs++;
    return pendingInstall?.future ?? snapshot('downloading', version: '0.2.0');
  }

  @override
  Future<Map<String, dynamic>> cancelUpdate() async {
    cancellations++;
    return snapshot('available', version: '0.2.0');
  }

  Completer<Map<String, dynamic>>? pending;
  Object? failure;
  @override
  void listen(ValueChanged<Map<String, dynamic>>? value) => listener = value;
  @override
  Future<Map<String, dynamic>> initialize() async {
    initializations++;
    return snapshot('idle');
  }

  @override
  Future<Map<String, dynamic>> checkForUpdates() async {
    checks++;
    if (failure != null) throw failure!;
    return pending?.future ?? snapshot('idle');
  }

  @override
  Future<Map<String, dynamic>> showUpdate() async {
    presentations++;
    return snapshot('available', version: '0.2.0');
  }

  void emit(String state, {String? version, String? error}) =>
      listener?.call(snapshot(state, version: version, error: error));
}

void main() {
  testWidgets('automatic checks start quietly after startup and repeat daily', (
    tester,
  ) async {
    final service = FakeUpdateService();
    final preferences = MemoryPreferences();
    final start = DateTime.utc(2026, 10, 9);
    var elapsed = Duration.zero;
    final updates = AppUpdates(
      service: service,
      preferences: preferences,
      now: () => start.add(elapsed),
    );
    await updates.initialize('macos');
    expect(updates.automaticallyCheckForUpdates, isTrue);
    updates.checkIfDue();
    expect(service.checks, 0);
    elapsed = const Duration(seconds: 30);
    await tester.pump(elapsed);
    expect(service.checks, 1);
    expect(service.presentations, 0);
    expect(updates.lastChecked, start.add(elapsed));
    elapsed += const Duration(hours: 23);
    await tester.pump(const Duration(hours: 23));
    updates.checkIfDue();
    expect(service.checks, 1);
    elapsed += const Duration(hours: 1);
    await tester.pump(const Duration(hours: 1));
    expect(service.checks, 2);
    expect(service.presentations, 0);
    updates.dispose();
  });

  testWidgets('opt out survives restart and manual checks remain available', (
    tester,
  ) async {
    final preferences = MemoryPreferences();
    final service = FakeUpdateService();
    final updates = AppUpdates(service: service, preferences: preferences);
    await updates.initialize('macos');
    await updates.setAutomaticallyCheckForUpdates(false);
    await tester.pump(const Duration(days: 2));
    expect(service.checks, 0);
    await updates.check();
    expect(service.checks, 1);
    updates.dispose();
    final restarted = AppUpdates(
      service: FakeUpdateService(),
      preferences: preferences,
    );
    addTearDown(restarted.dispose);
    await restarted.initialize('macos');
    expect(restarted.automaticallyCheckForUpdates, isFalse);
    restarted.dispose();
  });

  testWidgets('failure retries after one hour without presenting a window', (
    tester,
  ) async {
    final service = FakeUpdateService()
      ..failure = PlatformException(code: 'offline');
    final start = DateTime.utc(2026, 10, 9);
    var now = start;
    final updates = AppUpdates(
      service: service,
      preferences: MemoryPreferences(),
      now: () => now,
      startupDelay: Duration.zero,
    );
    await updates.initialize('macos');
    await updates.check();
    expect(service.checks, 1);
    expect(updates.error, 'offline');
    updates.checkIfDue();
    expect(service.checks, 1);
    service.failure = null;
    now = start.add(const Duration(hours: 1));
    await tester.pump(const Duration(hours: 1));
    expect(service.checks, 2);
    expect(updates.error, isNull);
    expect(service.presentations, 0);
    updates.dispose();
  });

  testWidgets(
    'native async results update availability and persist completion time',
    (tester) async {
      final service = FakeUpdateService();
      final preferences = MemoryPreferences();
      final updates = AppUpdates(service: service, preferences: preferences);
      await updates.initialize('macos');
      service.pending = Completer();
      final check = updates.check();
      await updates.check();
      expect(service.checks, 1);
      service.pending!.complete(snapshot('checking'));
      await check;
      expect(updates.lastChecked, isNull);
      service.emit('available', version: '0.2.0');
      await tester.pump();
      expect(updates.hasUpdate, isTrue);
      expect(updates.canShowUpdate, isTrue);
      expect(preferences.checked, updates.lastChecked);
      await updates.showUpdate();
      expect(service.presentations, 1);
      expect(updates.hasUpdate, isTrue);
      await updates.setAutomaticallyCheckForUpdates(false);
      expect(updates.hasUpdate, isTrue);
      updates.dispose();
    },
  );

  testWidgets('late check response preserves the newer availability event', (
    tester,
  ) async {
    final service = FakeUpdateService();
    final preferences = MemoryPreferences();
    final start = DateTime.utc(2026, 10, 9, 9);
    var now = start;
    final updates = AppUpdates(
      service: service,
      preferences: preferences,
      now: () => now,
      startupDelay: Duration.zero,
    );
    addTearDown(updates.dispose);
    await updates.initialize('macos');
    service.pending = Completer<Map<String, dynamic>>();
    final check = updates.check();
    expect(updates.checking, isTrue);

    now = start.add(const Duration(minutes: 1));
    service.emit('available', version: '0.2.0');
    await tester.pump(const Duration(minutes: 1));
    final completedAt = now;
    expect(updates.status, UpdateStatus.available);
    expect(updates.lastChecked, completedAt);
    expect(preferences.checked, completedAt);
    expect(updates.canCheck, isFalse);

    now = start.add(const Duration(minutes: 2));
    service.pending!.complete(snapshot('checking'));
    await check;
    await tester.pump(const Duration(minutes: 1));
    expect(updates.status, UpdateStatus.available);
    expect(updates.version, '0.2.0');
    expect(updates.hasUpdate, isTrue);
    expect(updates.canCheck, isTrue);
    expect(updates.canShowUpdate, isTrue);
    expect(updates.lastChecked, completedAt);
    expect(preferences.checked, completedAt);
    expect(service.checks, 1);
    expect(service.presentations, 0);
    updates.dispose();
  });

  testWidgets('recent success does not delay the one-hour failure retry', (
    tester,
  ) async {
    final service = FakeUpdateService();
    final preferences = MemoryPreferences();
    final start = DateTime.utc(2026, 10, 9, 9);
    var now = start;
    final updates = AppUpdates(
      service: service,
      preferences: preferences,
      now: () => now,
      startupDelay: Duration.zero,
    );
    addTearDown(updates.dispose);
    await updates.initialize('macos');
    await updates.check();
    expect(service.checks, 1);
    expect(updates.lastChecked, start);
    expect(preferences.checked, start);

    now = start.add(const Duration(hours: 1));
    await tester.pump(const Duration(hours: 1));
    service.failure = PlatformException(code: 'offline');
    await updates.check();
    expect(service.checks, 2);
    expect(updates.status, UpdateStatus.error);
    expect(updates.error, 'offline');
    expect(updates.lastChecked, start);
    expect(preferences.checked, start);
    service.failure = null;

    now = start.add(const Duration(hours: 1, minutes: 59, seconds: 59));
    await tester.pump(const Duration(minutes: 59, seconds: 59));
    updates.checkIfDue();
    expect(service.checks, 2);
    expect(updates.lastChecked, start);
    expect(preferences.checked, start);

    now = start.add(const Duration(hours: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(service.checks, 3);
    expect(updates.status, UpdateStatus.idle);
    expect(updates.error, isNull);
    expect(updates.lastChecked, now);
    expect(preferences.checked, now);
    expect(service.presentations, 0);
    updates.dispose();
  });

  testWidgets('failed preference save keeps the previous preference', (
    tester,
  ) async {
    final preferences = MemoryPreferences()..failWrite = true;
    final updates = AppUpdates(
      service: FakeUpdateService(),
      preferences: preferences,
    );
    await updates.initialize('macos');
    await updates.setAutomaticallyCheckForUpdates(false);
    expect(updates.automaticallyCheckForUpdates, isTrue);
    expect(updates.savingPreference, isFalse);
    expect(updates.error, contains('Cannot save'));
    updates.dispose();
  });

  testWidgets('install blocks double clicks and preserves newer ready events', (
    tester,
  ) async {
    final service = FakeUpdateService()..pendingInstall = Completer();
    final updates = AppUpdates(
      service: service,
      preferences: MemoryPreferences()..automatic = false,
    );
    await updates.initialize('macos');
    service.listener?.call({
      ...snapshot('available', version: '0.2.0'),
      'revision': 10,
      'capabilities': {'installUpdate': true},
    });
    final install = updates.install();
    await updates.install();
    expect(service.installs, 1);
    expect(updates.canInstall, isFalse);
    service.listener?.call({
      ...snapshot('ready', version: '0.2.0'),
      'revision': 12,
      'capabilities': {'installUpdate': true, 'cancelUpdate': true},
    });
    service.pendingInstall!.complete({
      ...snapshot('downloading', version: '0.2.0'),
      'revision': 11,
    });
    await install;
    expect(updates.status, UpdateStatus.ready);
    expect(updates.canInstall, isTrue);
    expect(updates.canCancel, isTrue);
    updates.dispose();
  });

  testWidgets('older native events cannot overwrite download state', (
    tester,
  ) async {
    final service = FakeUpdateService();
    final updates = AppUpdates(
      service: service,
      preferences: MemoryPreferences()..automatic = false,
    );
    await updates.initialize('macos');
    service.listener?.call({
      ...snapshot('downloading', version: '0.2.0'),
      'revision': 3,
      'progress': 0.42,
      'releaseNotes': 'Improved playback.',
      'capabilities': {'cancelUpdate': true},
    });
    service.listener?.call({
      ...snapshot('available', version: '0.2.0'),
      'revision': 2,
    });
    expect(updates.status, UpdateStatus.downloading);
    expect(updates.progress, 0.42);
    expect(updates.releaseNotes, 'Improved playback.');
    expect(updates.canCancel, isTrue);
    await updates.cancel();
    expect(service.cancellations, 1);
    expect(updates.status, UpdateStatus.available);
    updates.dispose();
  });

  testWidgets('missing host capabilities prevent install and cancellation', (
    tester,
  ) async {
    final service = FakeUpdateService();
    final updates = AppUpdates(
      service: service,
      preferences: MemoryPreferences()..automatic = false,
    );
    await updates.initialize('macos');
    await updates.install();
    await updates.cancel();
    expect(service.installs, 0);
    expect(service.cancellations, 0);
    updates.dispose();
  });

  testWidgets('Android shares update scheduling and uses system installation', (
    tester,
  ) async {
    final service = FakeUpdateService();
    final updates = AppUpdates(
      service: service,
      preferences: MemoryPreferences(),
    );
    await updates.initialize('android');
    expect(service.initializations, 1);
    expect(updates.supported, isTrue);
    expect(updates.requiresSystemInstall, isTrue);
    await tester.pump(const Duration(seconds: 30));
    expect(service.checks, 1);
    updates.dispose();
  });

  testWidgets('unsupported hosts never touch the native channel', (
    tester,
  ) async {
    for (final platform in ['windows', 'linux', 'ios']) {
      final service = FakeUpdateService();
      final updates = AppUpdates(
        service: service,
        preferences: MemoryPreferences(),
      );
      await updates.initialize(platform);
      await updates.check();
      await tester.pump(const Duration(days: 2));
      expect(updates.supported, isFalse);
      expect(service.initializations, 0);
      expect(service.checks, 0);
      updates.dispose();
    }
  });

  testWidgets('dispose cancels checks and ignores an in-flight response', (
    tester,
  ) async {
    final service = FakeUpdateService()..pending = Completer();
    final updates = AppUpdates(
      service: service,
      preferences: MemoryPreferences(),
    );
    await updates.initialize('macos');
    final check = updates.check();
    updates.dispose();
    service.pending!.complete(snapshot('available', version: '0.2.0'));
    await check;
    await tester.pump(const Duration(days: 2));
    expect(service.listener, isNull);
    expect(service.checks, 1);
    expect(updates.hasUpdate, isFalse);
  });
}
