// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter_airplay/app/receiver_app.dart';
import 'package:flutter_airplay/l10n/generated/app_localizations_en.dart';
import 'package:flutter_airplay/platform/app_updates.dart';
import 'package:flutter_airplay/platform/desktop_presentation.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/receiver/fake_receiver.dart';

class _Preferences extends AppUpdatePreferences {
  bool automatic = true;
  @override
  Future<bool> readAutomaticallyCheck() async => automatic;
  @override
  Future<void> writeAutomaticallyCheck(bool value) async => automatic = value;
  @override
  Future<DateTime?> readLastChecked() async => null;
  @override
  Future<void> writeLastChecked(DateTime value) async {}
}

class _Service extends AppUpdateService {
  ValueChanged<Map<String, dynamic>>? listener;
  int checks = 0, presentations = 0, installs = 0, cancellations = 0;
  Map<String, dynamic> state = {
    'enabled': true,
    'status': 'idle',
    'capabilities': {
      'checkForUpdates': true,
      'showUpdate': true,
      'installUpdate': true,
      'cancelUpdate': true,
    },
  };
  @override
  void listen(ValueChanged<Map<String, dynamic>>? value) => listener = value;
  @override
  Future<Map<String, dynamic>> initialize() async => state;
  @override
  Future<Map<String, dynamic>> checkForUpdates() async {
    checks++;
    return state;
  }

  @override
  Future<Map<String, dynamic>> showUpdate() async {
    presentations++;
    return state;
  }

  @override
  Future<Map<String, dynamic>> installUpdate() async {
    installs++;
    state = {...state, 'status': 'downloading', 'progress': 0.42};
    return state;
  }

  @override
  Future<Map<String, dynamic>> cancelUpdate() async {
    cancellations++;
    state = {...state, 'status': 'available', 'progress': null};
    return state;
  }

  void ready() {
    state = {...state, 'status': 'ready', 'progress': null};
    listener?.call(state);
  }

  void available() {
    state = {
      ...state,
      'status': 'available',
      'version': '0.2.0',
      'releaseNotes': 'Improved playback stability and connection recovery.',
    };
    listener?.call(state);
  }
}

final _captureKey = GlobalKey();

Future<void> _capture(String name) async {
  if (!Platform.isMacOS ||
      !const bool.fromEnvironment('AIRPLAY_UPDATE_SCREENSHOTS')) {
    return;
  }
  final directory = Directory('artifacts/updates-ui')
    ..createSync(recursive: true);
  final boundary =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('${directory.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'macOS update entry points share state without interrupting playback',
    (tester) async {
      if (!Platform.isMacOS) return;
      final window = const WindowController();
      final host = AppUpdates(preferences: _Preferences());
      await host.initialize('macos');
      expect(host.initialized, isTrue);
      expect(host.supported, isTrue);
      if (!host.enabled) expect(host.unavailableReason, isNotEmpty);
      host.dispose();

      final service = _Service();
      final preferences = _Preferences();
      final updates = AppUpdates(service: service, preferences: preferences);
      final backend = FakeReceiver(
        buildVersion: '0.1.4 (5)',
        capabilities: {'platform': 'macos', 'nativeVideoSurface': true},
      );
      final model = ReceiverModel(backend);
      await tester.pumpWidget(
        RepaintBoundary(
          key: _captureKey,
          child: ReceiverApp(model: model, updates: updates),
        ),
      );
      await tester.pumpAndSettle();
      await window.withWindow((value) {
        value.show();
        value.focus();
      });
      expect(find.byKey(const Key('appUpdateIndicator')), findsNothing);
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('automaticallyCheckForUpdates')),
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('automaticallyCheckForUpdates')),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('automaticallyCheckForUpdates')));
      await tester.pumpAndSettle();
      expect(preferences.automatic, isFalse);
      await tester.tap(find.byKey(const Key('appUpdateAction')));
      await tester.pumpAndSettle();
      expect(service.checks, 1);
      expect(service.presentations, 0);
      await tester.tap(find.byKey(const Key('closeSettings')));
      await tester.pumpAndSettle();

      backend.state('streaming');
      backend.controller.add({
        'type': 'media',
        'audioPlaying': true,
        'videoPaused': false,
      });
      service.available();
      await tester.pumpAndSettle();
      expect(backend.stops, 0);
      expect(service.presentations, 0);
      expect(find.byKey(const Key('appUpdateIndicator')), findsOneWidget);
      await tester.tap(find.byKey(const Key('appUpdateIndicator')));
      await tester.pumpAndSettle();
      expect(service.presentations, 0);
      expect(find.byKey(const Key('appUpdateDialog')), findsOneWidget);
      await tester.runAsync(() => _capture('available'));
      await tester.tap(find.byKey(const Key('appUpdatePrimaryAction')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(service.installs, 1);
      expect(updates.status, UpdateStatus.downloading);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byKey(const Key('appUpdateIndicatorProgress')),
            )
            .value,
        0.42,
      );
      await tester.runAsync(() => _capture('downloading'));
      await tester.tap(find.byKey(const Key('closeAppUpdate')));
      await tester.pumpAndSettle();
      expect(service.cancellations, 0);
      await tester.tap(find.byKey(const Key('appUpdateIndicator')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('appUpdateDialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('cancelAppUpdate')));
      await tester.pumpAndSettle();
      expect(service.cancellations, 1);
      service.ready();
      await tester.pumpAndSettle();
      await tester.runAsync(() => _capture('ready'));
      await tester.tap(find.byKey(const Key('closeAppUpdate')));
      await tester.pumpAndSettle();
      service.available();
      await tester.pumpAndSettle();

      final desktop = DesktopPresentation(
        window: window,
        model: model,
        updates: updates,
        onAction: (_, _) async {},
        onError: (error) => fail(error.toString()),
      );
      await desktop.update(AppLocalizationsEn());
      final menu = desktop.menuForTesting;
      expect(menu, isNotNull);
      expect(
        menu!.allItems.map((item) => item.label),
        contains('Update to 0.2.0…'),
      );
      await desktop.dispose();
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('appUpdateAction')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => _capture('settings'));
      await tester.tap(find.byKey(const Key('appUpdateAction')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('appUpdateDialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('appUpdateIndicator')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('appUpdateDialog')), findsOneWidget);
      expect(service.presentations, 0);
      await tester.tap(find.byKey(const Key('closeAppUpdate')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('closeSettings')), findsOneWidget);
      expect(backend.stops, 0);
      await tester.pumpWidget(const SizedBox());
      await backend.controller.close();
    },
  );
}
