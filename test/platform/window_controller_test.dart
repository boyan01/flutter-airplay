import 'package:flutter/services.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nativeapi/nativeapi.dart' as native;

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
  test('video geometry uses the active display, preserves center and clears aspect on home', () async {
    final display = FakeDisplay();
    final geometry = WindowController(
      withWindow: (action) async => action(window),
      getDisplays: () => [display],
    );
    await geometry.setMode(playing: true, width: 1920, height: 1080);
    expect(window.contentSize.width, closeTo(1280, .01));
    expect(window.contentSize.height, closeTo(720, .01));
    expect(window.aspectRatio, 16 / 9);
    expect(window.minimumSize.width, 160);
    expect(
      window.position.x,
      0,
    ); // The old center would put the frame outside the display.
    expect(display.disposed, isTrue);
    await geometry.setMode(playing: false, width: 0, height: 0);
    expect(window.contentSize, const native.Size(width: 440, height: 560));
    expect(window.aspectRatio, 0);
    expect(window.minimumSize, const native.Size(width: 360, height: 480));
  });
  test(
    'fullscreen and maximized defer mode changes until restoration',
    () async {
      final geometry = WindowController(
        withWindow: (action) async => action(window),
        getDisplays: () => throw StateError('must not resize'),
      );
      window.fullscreen = true;
      await geometry.setMode(playing: true, width: 1920, height: 1080);
      window.fullscreen = false;
      window.maximized = true;
      await geometry.setMode(playing: false, width: 0, height: 0);
      expect(window.contentSize, const native.Size(width: 440, height: 560));
    },
  );
  test(
    'actual pixels respect DPI, fit bounds and negative monitor origins',
    () {
      final target = WindowController.fitBounds(
        previous: const native.Rectangle(
          x: -1000,
          y: 0,
          width: 440,
          height: 560,
        ),
        workArea: const native.Rectangle(
          x: -1600,
          y: 0,
          width: 1600,
          height: 1000,
        ),
        videoWidth: 640,
        videoHeight: 360,
        scaleFactor: 2,
        actualSize: true,
      );
      expect(target.width, 320);
      expect(target.height, 180);
      expect(target.x, -940);
      expect(target.y, 190);
      final portrait = WindowController.fitBounds(
        previous: target,
        workArea: const native.Rectangle(
          x: -1600,
          y: 0,
          width: 1600,
          height: 1000,
        ),
        videoWidth: 1080,
        videoHeight: 1920,
      );
      expect(portrait.height, 800);
      expect(portrait.width, 450);
      expect(portrait.x + portrait.width, lessThanOrEqualTo(0));
    },
  );
}

class FakeDisplay implements native.Display {
  bool disposed = false;
  @override
  native.Rectangle get workArea =>
      const native.Rectangle(x: 0, y: 0, width: 1600, height: 1000);
  @override
  double get scaleFactor => 2;
  @override
  void dispose() => disposed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
