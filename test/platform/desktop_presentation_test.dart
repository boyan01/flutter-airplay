import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_airplay/l10n/generated/app_localizations_en.dart';
import 'package:flutter_airplay/platform/desktop_presentation.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../receiver/fake_receiver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tech.soit.flutterairplay/window');

  test(
    'disposal waits for startup and prevents late resource creation',
    () async {
      final backend = FakeReceiver(
        autoStart: false,
        capabilities: {'platform': 'macos'},
      );
      final model = ReceiverModel(backend);
      await model.initialize();
      final startup = Completer<bool>();
      final started = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'desktopReady') {
              started.complete();
              return startup.future;
            }
            fail('Unexpected host call after disposal: ${call.method}');
          });
      var windowCalls = 0;
      final desktop = DesktopPresentation(
        window: WindowController(withWindow: (_) async => windowCalls++),
        model: model,
        onAction: (_, _) async {},
        onError: (_) {},
      );
      try {
        final update = desktop.update(AppLocalizationsEn());
        await started.future;
        var disposed = false;
        final disposal = desktop.dispose().then((_) => disposed = true);
        await Future<void>.delayed(Duration.zero);
        expect(disposed, isFalse);
        startup.complete(true);
        await Future.wait([update, disposal]);
        expect(disposed, isTrue);
        expect(windowCalls, 0);
        await desktop.dispose();
      } finally {
        model.dispose();
        await backend.controller.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );

  test('failed desktop initialization restores visible host fallback and can retry', () async {
    final backend = FakeReceiver(
      autoStart: false,
      capabilities: {'platform': 'linux'},
    );
    final model = ReceiverModel(backend);
    await model.initialize();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'desktopReady') {
            throw PlatformException(code: 'desktop_unavailable');
          }
          return null;
        });
    final desktop = DesktopPresentation(
      window: const WindowController(),
      model: model,
      onAction: (_, _) async {},
      onError: (_) {},
    );
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          desktop.update(AppLocalizationsEn()),
          throwsA(isA<PlatformException>()),
        );
      }
      expect(calls.map((call) => call.method), [
        'desktopReady',
        'setClosePolicy',
        'finishDesktopStartup',
        'desktopReady',
        'setClosePolicy',
        'finishDesktopStartup',
      ]);
      expect(
        calls
            .where((call) => call.method != 'desktopReady')
            .map((call) => call.arguments),
        everyElement(false),
      );
      desktop.dispose();
      calls.clear();
      await desktop.update(AppLocalizationsEn());
      expect(calls, isEmpty);
    } finally {
      desktop.dispose();
      model.dispose();
      await backend.controller.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
}
