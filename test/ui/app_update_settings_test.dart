import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_airplay/l10n/generated/app_localizations.dart';
import 'package:flutter_airplay/platform/app_updates.dart';
import 'package:flutter_airplay/platform/launch_at_login.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_airplay/ui/settings/app_update_settings.dart';
import 'package:flutter_airplay/ui/settings/settings_page.dart';
import 'package:flutter_airplay/ui/widgets/app_update_strings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../receiver/fake_receiver.dart';

class _FakeService extends AppUpdateService {
  @override
  void listen(ValueChanged<Map<String, dynamic>>? listener) {}
}

class _FakePreferences implements AppUpdatePreferences {
  @override
  Future<bool> readAutomaticallyCheck() async => true;
  @override
  Future<DateTime?> readLastChecked() async => null;
  @override
  Future<void> writeAutomaticallyCheck(bool value) async {}
  @override
  Future<void> writeLastChecked(DateTime value) async {}
}

class _FakeUpdates extends AppUpdates {
  _FakeUpdates()
    : super(service: _FakeService(), preferences: _FakePreferences()) {
    initialized = supported = enabled = true;
  }

  bool allowCheck = true;
  int checks = 0, writes = 0;
  Completer<void>? preferenceWrite;

  @override
  bool get canCheck => enabled && !checking && allowCheck;

  @override
  Future<void> check() async {
    checks++;
    status = UpdateStatus.checking;
    notifyListeners();
  }

  @override
  Future<void> setAutomaticallyCheckForUpdates(bool value) async {
    writes++;
    savingPreference = true;
    notifyListeners();
    await preferenceWrite?.future;
    automaticallyCheckForUpdates = value;
    savingPreference = false;
    notifyListeners();
  }

  void publish() => notifyListeners();
}

class _FakeLogin extends LaunchAtLogin {
  @override
  Future<bool> isEnabled() async => false;
}

void main() {
  Future<void> open(
    WidgetTester tester,
    _FakeUpdates updates, {
    ReceiverModel? model,
    Locale locale = const Locale('en'),
    VoidCallback? onOpenUpdate,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: model == null
              ? SingleChildScrollView(
                  child: AppUpdateSettings(
                    updates: updates,
                    onOpenUpdate: onOpenUpdate,
                  ),
                )
              : SettingsPage(
                  model: model,
                  updates: updates,
                  launchAtLogin: _FakeLogin(),
                  editName: false,
                  onLogs: () {},
                ),
        ),
      ),
    );
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      updates.dispose();
    });
  }

  SwitchListTile automatic(WidgetTester tester) =>
      tester.widget(find.byKey(const Key('automaticallyCheckForUpdates')));

  ListTile action(WidgetTester tester) =>
      tester.widget(find.byKey(const Key('appUpdateAction')));

  testWidgets('automatic switch saves and prevents duplicate writes', (
    tester,
  ) async {
    final updates = _FakeUpdates()..preferenceWrite = Completer<void>();
    await open(tester, updates);
    expect(automatic(tester).value, true);
    expect(
      find.text('Check periodically. You choose when to install.'),
      findsOneWidget,
    );
    expect(updates.checks, 0);
    await tester.tap(find.byKey(const Key('automaticallyCheckForUpdates')));
    await tester.pump();
    expect(updates.writes, 1);
    expect(automatic(tester).onChanged, isNull);
    expect(find.text('Saving…'), findsOneWidget);
    expect(action(tester).onTap, isNotNull);
    updates.preferenceWrite!.complete();
    await tester.pump();
    expect(automatic(tester).value, false);
    expect(automatic(tester).onChanged, isNotNull);
  });

  testWidgets('configuration failure is explicit and disables the action', (
    tester,
  ) async {
    final updates = _FakeUpdates()
      ..enabled = false
      ..unavailableReason = 'Missing SUPublicEDKey';
    await open(tester, updates, locale: const Locale('zh'));
    expect(find.text('应用更新不可用，请检查更新配置。'), findsOneWidget);
    expect(find.text('Missing SUPublicEDKey'), findsOneWidget);
    expect(automatic(tester).onChanged, isNull);
    expect(action(tester).onTap, isNull);
    updates
      ..enabled = true
      ..unavailableReason = null;
    updates.publish();
    await tester.pump();
    expect(automatic(tester).onChanged, isNotNull);
    expect(action(tester).onTap, isNotNull);
  });

  testWidgets(
    'one settings action checks inline and disables duplicate checks',
    (tester) async {
      final updates = _FakeUpdates()..automaticallyCheckForUpdates = false;
      var opens = 0;
      await open(tester, updates, onOpenUpdate: () => opens++);
      expect(find.byKey(const Key('appUpdateAction')), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      await tester.tap(find.byKey(const Key('appUpdateAction')));
      await tester.pump();
      expect(updates.checks, 1);
      expect(opens, 0);
      expect(action(tester).onTap, isNull);
      expect(find.text('Checking for updates…'), findsOneWidget);
      expect(find.byKey(const Key('appUpdateSpinner')), findsOneWidget);
      expect(automatic(tester).onChanged, isNotNull);
      updates
        ..status = UpdateStatus.idle
        ..lastChecked = DateTime(2026, 10, 9, 14, 30);
      updates.publish();
      await tester.pump();
      expect(find.text('No new version available'), findsOneWidget);
      expect(find.textContaining('Last checked:'), findsOneWidget);
      expect(find.byKey(const Key('appUpdateSpinner')), findsNothing);
    },
  );

  testWidgets('failed check retries with automatic checks off', (tester) async {
    final updates = _FakeUpdates()
      ..automaticallyCheckForUpdates = false
      ..status = UpdateStatus.error
      ..error = 'Could not load appcast';
    await open(tester, updates);
    expect(find.text('Unable to check for updates'), findsOneWidget);
    expect(find.text('Could not load appcast'), findsOneWidget);
    expect(find.text('Retry update check'), findsOneWidget);
    await tester.tap(find.byKey(const Key('appUpdateAction')));
    await tester.pump();
    expect(updates.checks, 1);
    expect(action(tester).onTap, isNull);
  });

  testWidgets('available downloading and ready use the same open action', (
    tester,
  ) async {
    final updates = _FakeUpdates()
      ..status = UpdateStatus.available
      ..version = '2.1.0';
    var opens = 0;
    await open(tester, updates, onOpenUpdate: () => opens++);
    expect(find.text('Version 2.1.0 is available'), findsOneWidget);
    final strings = AppLocalizations.of(
      tester.element(find.byType(AppUpdateSettings)),
    )!;
    expect(updateActionLabel(strings, updates, tray: true), 'Update to 2.1.0…');
    await tester.tap(find.byKey(const Key('appUpdateAction')));
    expect(opens, 1);
    updates
      ..status = UpdateStatus.downloading
      ..progress = 0.42;
    updates.publish();
    await tester.pump();
    expect(find.text('Downloading update… 42%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    await tester.tap(find.byKey(const Key('appUpdateAction')));
    expect(opens, 2);
    updates
      ..status = UpdateStatus.ready
      ..progress = null;
    updates.publish();
    await tester.pump();
    expect(find.text('Update ready to install'), findsOneWidget);
    expect(find.text('Install and restart'), findsOneWidget);
    await tester.tap(find.byKey(const Key('appUpdateAction')));
    expect(opens, 3);
    expect(updates.checks, 0);
  });

  testWidgets('failed update opens details instead of adding another action', (
    tester,
  ) async {
    final updates = _FakeUpdates()
      ..status = UpdateStatus.error
      ..error = 'Download failed'
      ..version = '2.1.0';
    var opens = 0;
    await open(tester, updates, onOpenUpdate: () => opens++);
    expect(find.text('Download failed'), findsOneWidget);
    expect(find.text('View update'), findsOneWidget);
    expect(find.text('Retry update check'), findsNothing);
    await tester.tap(find.byKey(const Key('appUpdateAction')));
    expect(opens, 1);
    expect(updates.checks, 0);
  });

  testWidgets('idle distinguishes unchecked from no new version', (
    tester,
  ) async {
    final updates = _FakeUpdates();
    await open(tester, updates, locale: const Locale('zh'));
    expect(find.text('尚未检查更新'), findsOneWidget);
    updates.lastChecked = DateTime(2026, 10, 9, 14, 30);
    updates.publish();
    await tester.pump();
    expect(find.text('暂无新版本'), findsOneWidget);
    expect(find.textContaining('上次检查：'), findsOneWidget);
  });

  for (final platform in ['macos', 'windows', 'linux', 'android', 'ios']) {
    testWidgets('$platform settings expose supported update hosts', (
      tester,
    ) async {
      final backend = FakeReceiver(
        autoStart: false,
        capabilities: {'platform': platform},
        buildVersion: '1.0.0',
      );
      final model = ReceiverModel(backend);
      await model.initialize();
      model
        ..status = 'streaming'
        ..busy = true;
      addTearDown(() async {
        model.dispose();
        await backend.controller.close();
      });
      final updates = _FakeUpdates();
      await open(tester, updates, model: model);
      expect(
        find.byType(AppUpdateSettings),
        ['macos', 'android'].contains(platform) ? findsOneWidget : findsNothing,
      );
      if (['macos', 'android'].contains(platform)) {
        await tester.ensureVisible(find.byType(AppUpdateSettings));
        await tester.pump();
        expect(automatic(tester).onChanged, isNotNull);
        expect(action(tester).onTap, isNotNull);
        automatic(tester).onChanged!(false);
        await tester.pump();
        expect(updates.writes, 1);
        expect(automatic(tester).value, false);
        action(tester).onTap!();
        await tester.pump();
        expect(updates.checks, 1);
      }
    });
  }

  testWidgets('narrow layout supports large text and unknown progress', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final updates = _FakeUpdates()
      ..status = UpdateStatus.downloading
      ..version = '2.1.0';
    var opens = 0;
    await open(
      tester,
      updates,
      locale: const Locale('zh'),
      onOpenUpdate: () => opens++,
    );
    expect(find.text('正在下载更新…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('appUpdateAction')));
    await tester.tap(find.byKey(const Key('appUpdateAction')));
    await tester.pump();
    expect(opens, 1);
    expect(tester.takeException(), isNull);
  });
}
