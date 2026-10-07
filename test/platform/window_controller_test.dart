import 'package:flutter/services.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tech.soit.flutterairplay/window');
  late FakeWindow window;
  late WindowController controller;
  setUp(() {
    window = FakeWindow();
    controller = WindowController(withWindow: (action) async => action(window));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          fail(
            'Window primitive must not use the host channel: ${call.method}',
          );
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'missing host window is reported and its lookup can be retried',
    () async {
      var requests = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getNativeWindowHandle');
            requests++;
            return requests == 1 ? null : 0;
          });
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          const WindowController().withWindow((_) => fail('No host window')),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'window_unavailable',
            ),
          ),
        );
      }
      expect(requests, 2);
    },
  );

  test(
    'fullscreen toggles and explicit targets use the same native window',
    () async {
      await controller.execute(WindowCommand.toggleFullscreen);
      expect(window.fullscreen, isTrue);
      await controller.execute(WindowCommand.toggleFullscreen);
      expect(window.fullscreen, isFalse);
      await controller.execute(WindowCommand.enterFullscreen);
      await controller.execute(WindowCommand.enterFullscreen);
      expect(window.fullscreen, isTrue);
      await controller.execute(WindowCommand.exitFullscreen);
      await controller.execute(WindowCommand.exitFullscreen);
      expect(window.fullscreen, isFalse);
    },
  );
  test('maximize restores fullscreen before maximizing a window', () async {
    window.fullscreen = true;
    await controller.execute(WindowCommand.toggleMaximize);
    expect(window.calls, ['fullscreen:false']);
    await controller.execute(WindowCommand.toggleMaximize);
    expect(window.maximized, isTrue);
    await controller.execute(WindowCommand.toggleMaximize);
    expect(window.maximized, isFalse);
    expect(window.calls, ['fullscreen:false', 'maximize', 'unmaximize']);
  });
  test('minimize and drag use nativeapi, and fullscreen cannot drag', () async {
    await controller.execute(WindowCommand.minimizeWindow);
    await controller.execute(WindowCommand.startDragging);
    window.fullscreen = true;
    await controller.execute(WindowCommand.startDragging);
    expect(window.calls, ['minimize', 'startDragging']);
  });
  test('Android orientation stays on the host without desktop FFI', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    final mobile = WindowController(
      withWindow: (_) async => fail('Android must not use desktop FFI'),
    );
    await mobile.setPlaybackOrientation(
      playing: true,
      width: 1920,
      height: 1080,
    );
    await mobile.setPlaybackOrientation(playing: false, width: 0, height: 0);
    expect(
      calls.map((call) => call.method),
      everyElement('setPlaybackOrientation'),
    );
    expect(calls.first.arguments, {
      'playing': true,
      'width': 1920,
      'height': 1080,
    });
    expect(calls.last.arguments, {'playing': false, 'width': 0, 'height': 0});
  });
  test(
    'desktop startup reports tray readiness independently of close policy',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'desktopReady') return true;
            if (call.method == 'finishDesktopStartup') return call.arguments;
            return null;
          });
      expect(await controller.initializeDesktop(), isTrue);
      await controller.setClosePolicy(false);
      expect(
        await controller.finishDesktopStartup(trayAvailable: true),
        isTrue,
      );
      expect(
        await controller.finishDesktopStartup(trayAvailable: false),
        isFalse,
      );
      expect(calls.map((call) => call.method), [
        'desktopReady',
        'setClosePolicy',
        'finishDesktopStartup',
        'finishDesktopStartup',
      ]);
      expect(calls.map((call) => call.arguments), [null, false, true, false]);
    },
  );
  test(
    'host can reject a reported tray before the window stays hidden',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => false);
      expect(
        await controller.finishDesktopStartup(trayAvailable: true),
        isFalse,
      );
    },
  );
  test('native window errors reach the caller', () async {
    final unavailable = WindowController(
      withWindow: (_) async {
        throw PlatformException(code: 'window_unavailable');
      },
    );
    await expectLater(
      unavailable.execute(WindowCommand.toggleFullscreen),
      throwsA(isA<PlatformException>()),
    );
  });
}
