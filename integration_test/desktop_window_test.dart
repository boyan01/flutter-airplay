// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:ui' show isRunningOnPlatformThread;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_airplay/app/receiver_app.dart';
import 'package:flutter_airplay/platform/desktop_presentation.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_airplay/l10n/generated/app_localizations_en.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nativeapi/nativeapi.dart' as native;

import '../test/receiver/fake_receiver.dart';
import 'desktop_window_state.dart';

// Read the actual OS window, rather than the requested dimensions or a fake
// controller. Frame and content sizes can differ on decorated desktop hosts.
class _WindowGeometry {
  _WindowGeometry(native.Window window)
    : frame = window.bounds,
      content = window.contentSize,
      aspectRatio = window.aspectRatio,
      fullscreen = window.isFullScreen,
      alwaysOnTop = window.isAlwaysOnTop;

  final native.Rectangle frame;
  final native.Size content;
  final double aspectRatio;
  final bool fullscreen;
  bool alwaysOnTop;

  bool sameFrame(_WindowGeometry other, {double tolerance = 3}) =>
      (frame.x - other.frame.x).abs() <= tolerance &&
      (frame.y - other.frame.y).abs() <= tolerance &&
      (frame.width - other.frame.width).abs() <= tolerance &&
      (frame.height - other.frame.height).abs() <= tolerance &&
      (content.width - other.content.width).abs() <= tolerance &&
      (content.height - other.content.height).abs() <= tolerance;

  bool hasRatio(double ratio) =>
      (aspectRatio - ratio).abs() < .001 &&
      (content.width / content.height - ratio).abs() < .01;

  @override
  String toString() =>
      'frame=(${frame.x}, ${frame.y}, ${frame.width}, ${frame.height}), '
      'content=(${content.width}, ${content.height}), '
      'aspect=$aspectRatio, fullscreen=$fullscreen, onTop=$alwaysOnTop';
}

Future<_WindowGeometry> _waitForWindow(
  WidgetTester tester,
  bool Function(_WindowGeometry) matches, {
  required String reason,
  Duration stableFor = const Duration(milliseconds: 600),
}) async {
  const controller = WindowController();
  const timeout = Duration(seconds: 15);
  final clock = Stopwatch()..start();
  Duration? stableSince;
  _WindowGeometry? previous, current;
  String step = 'start', lastSnapshot = 'not sampled';
  var samples = 0;
  var nextLog = const Duration(seconds: 2);
  logDesktopPhase('WAIT $reason; stableFor=${stableFor.inMilliseconds}ms');
  while (clock.elapsed < timeout) {
    final remaining = timeout - clock.elapsed;
    // Give native event loops and platform transitions real elapsed time.
    // Bound the awaited sample too: an outer polling deadline cannot interrupt it.
    current = await runDesktopPhase<_WindowGeometry>(
      tester,
      'sample: $reason',
      () async {
        step = 'native event-loop delay';
        await Future<void>.delayed(const Duration(milliseconds: 50));
        step = 'WindowController.withWindow / native geometry';
        late _WindowGeometry geometry;
        late Future<bool> above;
        await controller.withWindow((value) {
          geometry = _WindowGeometry(value);
          lastSnapshot = '$geometry';
          step = 'readWindowAlwaysOnTop / xprop';
          above = readWindowAlwaysOnTop(value);
        });
        geometry.alwaysOnTop = await above;
        step = 'sample complete';
        return geometry;
      },
      timeout: remaining < const Duration(seconds: 5)
          ? remaining
          : const Duration(seconds: 5),
      log: false,
      details: () => 'step=$step; last OS window=$lastSnapshot',
    );
    samples++;
    expect(tester.takeException(), isNull, reason: reason);
    if (matches(current)) {
      if (previous == null ||
          !current.sameFrame(previous, tolerance: 1) ||
          current.fullscreen != previous.fullscreen) {
        stableSince = clock.elapsed;
      }
      stableSince ??= clock.elapsed;
      if (clock.elapsed - stableSince >= stableFor) {
        logDesktopPhase(
          'SETTLED $reason after ${clock.elapsedMilliseconds}ms, '
          'samples=$samples; $current',
        );
        return current;
      }
    } else {
      stableSince = null;
    }
    if (clock.elapsed >= nextLog) {
      logDesktopPhase(
        'WAITING $reason after ${clock.elapsedMilliseconds}ms, '
        'samples=$samples, matching=${stableSince != null}; $current',
      );
      nextLog = clock.elapsed + const Duration(seconds: 2);
    }
    previous = current;
  }
  fail('$reason did not settle after 15s. Last OS window: $current');
}

Future<void> _settleWidgets(WidgetTester tester) =>
    runDesktopPhase(tester, 'Flutter frames settle', () async {
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
    });

Future<void> _executeWindow(
  WidgetTester tester,
  WindowController controller,
  WindowCommand command,
) => runDesktopPhase(
  tester,
  'window command: ${command.name}',
  () => controller.execute(command),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Native resizes can synchronously pump engine frames. Use production-like
  // frame scheduling rather than the live test binding's pointer-fade policy.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'real desktop buttons enter and leave fullscreen through nativeapi',
    (tester) async {
      expect(
        isRunningOnPlatformThread,
        isTrue,
        reason: 'Desktop FFI window calls require the platform thread',
      );
      late int hostHandle;
      await const WindowController().withWindow((window) {
        hostHandle = window.nativeObject.address;
        expect(hostHandle, greaterThan(0));
        window.hide();
      });
      await const WindowController().withWindow((window) {
        expect(window.nativeObject.address, hostHandle);
        expect(window.isVisible, isFalse);
        window.show();
        window.focus();
      });
      final backend = FakeReceiver(
        capabilities: {
          'platform': Platform.operatingSystem,
          'nativeVideoSurface': Platform.isMacOS,
          'supportsExecutablePath': Platform.isMacOS,
        },
      );
      await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
      await _settleWidgets(tester);
      final bar = find.byKey(
        Key(
          Platform.isMacOS
              ? 'macWindowBar'
              : '${Platform.operatingSystem}WindowBar',
        ),
      );
      final titleElement = tester.element(bar);
      final origin = tester.getTopLeft(bar);
      expect(
        find.ancestor(of: bar, matching: find.byType(Navigator)),
        findsNothing,
      );
      if (Platform.isMacOS) {
        final title = find.descendant(
          of: find.byKey(const Key('windowDragArea')),
          matching: find.byType(Text),
        );
        final width =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        expect(tester.getCenter(title).dx, closeTo(width / 2, 0.5));
      }
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.element(bar), same(titleElement));
      expect(tester.getTopLeft(bar), origin);
      await _settleWidgets(tester);
      await tester.tap(find.byKey(const Key('closeSettings')));
      await _settleWidgets(tester);

      late native.Window window;
      await const WindowController().withWindow((value) => window = value);
      addTearDown(
        () => cleanUpDesktop(tester, [
          (
            phase: 'buttons: close receiver stream',
            action: backend.controller.close,
          ),
        ]),
      );

      Future<void> waitForFullscreen(bool target) async {
        await _waitForWindow(
          tester,
          (value) => value.fullscreen == target,
          reason: 'fullscreen button target=$target',
          // AppKit's style changes before its Space transition finishes.
          stableFor: const Duration(seconds: 1),
        );
      }

      if (window.isFullScreen) {
        window.isFullScreen = false;
        await waitForFullscreen(false);
      }
      for (var cycle = 0; cycle < 2; cycle++) {
        if (Platform.isMacOS) {
          await tester.tap(find.byKey(const Key('windowFullscreen')));
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        }
        await waitForFullscreen(true);
        if (Platform.isMacOS) {
          await tester.tap(find.byKey(const Key('windowFullscreen')));
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        }
        await waitForFullscreen(false);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('receiver events preserve real window geometry across sessions', (
    tester,
  ) async {
    final backend = FakeReceiver(
      capabilities: {
        'platform': Platform.operatingSystem,
        'nativeVideoSurface': Platform.isMacOS,
      },
    );
    final model = ReceiverModel(backend);
    const controller = WindowController();
    Future<void> cleanUp() => cleanUpDesktop(tester, [
      // Restore visibility/fullscreen even if an assertion fails. ReceiverScreen
      // owns the model, its presentation and the native wrapper's disposal.
      (
        phase: 'geometry: exit fullscreen',
        action: () => controller.execute(WindowCommand.exitFullscreen),
      ),
      (
        phase: 'geometry: show window',
        action: () => controller.withWindow((value) => value.show()),
      ),
      (
        phase: 'geometry: unmount ReceiverApp',
        action: () => tester.pumpWidget(const SizedBox()),
      ),
      (
        phase: 'geometry: close receiver stream',
        action: backend.controller.close,
      ),
    ]);
    // The binding unmounts via runApp and awaits a live frame before addTearDown.
    // Keep receiver/native disposal out of that uninstrumented warm-up frame;
    // clean up inside the test body with bounded phases, including on failure.
    try {
      await tester.pumpWidget(ReceiverApp(model: model, window: controller));
      await _waitForWindow(
        tester,
        (value) =>
            model.loaded && model.status == 'waiting' && !value.fullscreen,
        reason: 'receiver application startup',
      );

      // Simulate a user-resized and moved idle window before any sender connects.
      // The restored frame must be this one, not the launch default of 440x560.
      await controller.withWindow((value) {
        value.aspectRatio = 0;
        value.contentSize = const native.Size(width: 520, height: 600);
        value.position = const native.Point(x: 80, y: 70);
      });
      final baseline = await _waitForWindow(
        tester,
        (value) =>
            (value.content.width - 520).abs() <= 3 &&
            (value.content.height - 600).abs() <= 3 &&
            value.aspectRatio == 0,
        reason: 'nondefault idle frame',
      );
      Future<_WindowGeometry> expectVideo(
        int width,
        int height,
        String reason,
      ) async {
        final geometry = await _waitForWindow(
          tester,
          (value) =>
              !value.fullscreen &&
              value.hasRatio(width / height) &&
              model.status == 'streaming' &&
              model.videoWidth == width &&
              model.videoHeight == height,
          reason: reason,
        );
        // Also check Flutter's video viewport: correct native frame dimensions
        // alone would miss leftover titlebar padding or device-switch sidebars.
        final player = find.byKey(const Key('playerPage'));
        final video = find.descendant(
          of: player,
          matching: find.byType(AspectRatio),
        );
        expect(video, findsOneWidget);
        final viewportSize = tester.getSize(player);
        final videoSize = tester.getSize(video);
        expect(videoSize.width, closeTo(viewportSize.width, 2), reason: reason);
        expect(
          videoSize.height,
          closeTo(viewportSize.height, 2),
          reason: reason,
        );
        return geometry;
      }

      Future<_WindowGeometry> expectBaseline(String reason) => _waitForWindow(
        tester,
        (value) =>
            !value.fullscreen &&
            value.aspectRatio == 0 &&
            value.sameFrame(baseline),
        reason: reason,
      );

      backend.state('streaming');
      await _waitForWindow(
        tester,
        (value) => value.sameFrame(baseline) && value.aspectRatio == 0,
        reason: 'connection without a decoded video frame keeps idle geometry',
      );
      frame(backend, 1536, 2048);
      await expectVideo(1536, 2048, 'iPad portrait');
      frame(backend, 2048, 1536);
      await expectVideo(2048, 1536, 'iPad landscape');
      backend.state('waiting');
      await expectBaseline('iPad disconnect restores the complete idle frame');

      frame(backend, 2048, 1536);
      await expectVideo(2048, 1536, 'iPad reconnect');
      backend.state('waiting');
      backend.state('streaming');
      await expectBaseline(
        'new connection without a frame restores the previous session',
      );
      frame(backend, 2048, 1536);
      await expectVideo(
        2048,
        1536,
        'video after reconnect waiting for first frame',
      );
      // No pump or await between sessions: the old restore and new video resize
      // compete in the production presentation queue.
      backend.state('waiting');
      frame(backend, 1170, 2532);
      await expectVideo(
        1170,
        2532,
        'immediate iPhone session wins over restore',
      );
      frame(backend, 2532, 1170);
      // Interrupt a rotation that has already begun, then coalesce a same-turn
      // burst. The final portrait must win over the older landscape animation.
      await tester.pump(const Duration(milliseconds: 150));
      for (var rotation = 0; rotation < 5; rotation++) {
        frame(backend, 1170, 2532);
        frame(backend, 2532, 1170);
      }
      frame(backend, 1170, 2532);
      final phone = await expectVideo(
        1170,
        2532,
        'latest dimensions win a rapid rotation burst',
      );

      media(backend, paused: true);
      expect(model.status, 'streaming');
      expect(model.hasVideo, isFalse);
      await _waitForWindow(
        tester,
        (value) => value.sameFrame(phone) && value.hasRatio(1170 / 2532),
        reason: 'paused video0 retains the session geometry',
      );
      media(backend, audio: false);
      expect(model.status, 'streaming');
      expect(model.videoPaused, isFalse);
      await _waitForWindow(
        tester,
        (value) => value.sameFrame(phone) && value.hasRatio(1170 / 2532),
        reason: 'decoder reset video0 retains the session geometry',
      );
      backend.state('waiting');
      await expectBaseline(
        'iPhone disconnect restores the original idle frame',
      );

      frame(backend, 1536, 2048);
      await expectVideo(1536, 2048, 'video before fullscreen disconnect');
      await _executeWindow(tester, controller, WindowCommand.enterFullscreen);
      final fullscreen = await _waitForWindow(
        tester,
        (value) => value.fullscreen,
        reason: 'enter fullscreen before disconnect',
        stableFor: const Duration(seconds: 1),
      );
      backend.state('waiting');
      await _waitForWindow(
        tester,
        (value) => value.fullscreen && value.sameFrame(fullscreen),
        reason: 'disconnect defers idle-frame restoration while fullscreen',
      );
      await _executeWindow(tester, controller, WindowCommand.exitFullscreen);
      await expectBaseline('fullscreen exit applies the deferred idle frame');

      frame(backend, 2048, 1536);
      await expectVideo(2048, 1536, 'video before fullscreen rotation');
      await _executeWindow(tester, controller, WindowCommand.enterFullscreen);
      final rotatingFullscreen = await _waitForWindow(
        tester,
        (value) => value.fullscreen,
        reason: 'enter fullscreen before rotations',
        stableFor: const Duration(seconds: 1),
      );
      frame(backend, 1536, 2048);
      frame(backend, 2048, 1536);
      frame(backend, 1536, 2048);
      await _waitForWindow(
        tester,
        (value) => value.fullscreen && value.sameFrame(rotatingFullscreen),
        reason: 'rotations do not change the fullscreen frame',
      );
      await _executeWindow(tester, controller, WindowCommand.exitFullscreen);
      await expectVideo(
        1536,
        2048,
        'fullscreen exit applies the latest rotation',
      );
      backend.state('waiting');
      await expectBaseline('final disconnect restores the saved idle frame');
    } finally {
      await cleanUp();
    }
  });

  testWidgets(
    'desktop tray follows receiver state and keeps sizing in the player',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final backend = FakeReceiver(
        autoStart: false,
        capabilities: {
          'platform': Platform.operatingSystem,
          'nativeVideoSurface': Platform.isMacOS,
        },
      );
      final model = ReceiverModel(backend);
      await model.initialize();
      const controller = WindowController();
      final presentation = DesktopPresentation(
        window: controller,
        model: model,
        onAction: (_, _) async {},
        onError: (error) => fail('$error'),
      );
      addTearDown(
        () => cleanUpDesktop(tester, [
          (phase: 'tray: dispose presentation', action: presentation.dispose),
          (
            phase: 'tray: release native window',
            action: controller.releaseNativeWindow,
          ),
          (phase: 'tray: dispose model', action: () async => model.dispose()),
          (
            phase: 'tray: close receiver stream',
            action: backend.controller.close,
          ),
        ]),
      );
      final strings = AppLocalizationsEn();
      Future<void> update() async {
        await runDesktopPhase(
          tester,
          'tray update: status=${model.status}, video=${model.videoWidth}x${model.videoHeight}',
          () => presentation.update(strings),
        );
        await _settleWidgets(tester);
      }

      Map<String, bool> readMenu() {
        final menu = presentation.menuForTesting!;
        final items = menu.allItems;
        try {
          return {
            for (final item in items)
              if (item.type != native.MenuItemType.separator)
                item.label!: item.isEnabled,
          };
        } finally {
          for (final item in items) {
            item.dispose();
          }
        }
      }

      await update();
      if (!native.TrayManager.instance.isSupported()) return;
      expect(readMenu().keys, [
        model.name,
        'Receiver off',
        'Show window',
        'Start receiving',
        'Settings…',
        'View logs…',
        'Quit Flutter AirPlay',
      ]);
      await model.start('Living room', '');
      model.name = 'Next session';
      await update();
      expect(readMenu().keys.take(4), [
        'Living room',
        'Waiting for connection',
        'Show window',
        'Stop receiving',
      ]);
      backend.state('streaming');
      backend.controller.add({'type': 'client', 'name': 'Test iPad'});
      await update();
      expect(readMenu(), containsPair('Connecting… · Test iPad', false));
      expect(readMenu(), containsPair('Disconnect current connection', true));
      model.busy = true;
      await update();
      expect(readMenu(), containsPair('Disconnect current connection', false));
      expect(readMenu(), containsPair('Stop receiving', false));
      model.busy = false;
      frame(backend, 640, 360);
      await update();
      expect(readMenu(), containsPair('Mirroring · Test iPad', false));
      expect(readMenu(), containsPair('Enter Full Screen', true));
      expect(readMenu(), containsPair('Keep player on top', true));
      expect(readMenu(), isNot(contains('Actual Size')));
      expect(readMenu(), isNot(contains('Fit to Screen')));
      media(backend);
      await update();
      expect(readMenu(), containsPair('Audio playing · Test iPad', false));
      expect(readMenu(), isNot(contains('Enter Full Screen')));
      expect(readMenu(), isNot(contains('Keep player on top')));
      backend.state('stopping');
      await update();
      expect(readMenu(), containsPair('Stopping…', false));
      expect(readMenu(), containsPair('Stop receiving', false));
      expect(readMenu(), isNot(contains('Disconnect current connection')));
      backend.state('error');
      model.message = 'A long native diagnostic that belongs in logs';
      await update();
      expect(readMenu(), containsPair('Receiver failed', false));
      expect(readMenu(), containsPair('Start receiving', true));
      expect(readMenu(), isNot(contains(model.message)));
    },
  );

  testWidgets('shared desktop geometry, tray and session window policy', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final backend = FakeReceiver(
      autoStart: false,
      capabilities: {
        'platform': Platform.operatingSystem,
        'nativeVideoSurface': Platform.isMacOS,
      },
    );
    final model = ReceiverModel(backend);
    await model.initialize();
    const controller = WindowController();
    late native.Window nativeWindow;
    await controller.withWindow((value) => nativeWindow = value);
    final errors = <PlatformException>[];
    late DesktopPresentation presentation;
    presentation = DesktopPresentation(
      window: controller,
      model: model,
      onError: errors.add,
      onAction: (action, _) async {
        if (action == WindowAction.windowTransitionStarted) {
          presentation.transitionStarted();
        }
        if (action == WindowAction.windowStateChanged ||
            action == WindowAction.nativeWindowStateChanged) {
          await presentation.stateChanged(
            transitionCompleted: action == WindowAction.windowStateChanged,
          );
        }
        if (action == WindowAction.closeRequested) await presentation.hide();
      },
    );
    controller.listen(presentation.onAction);
    addTearDown(
      () => cleanUpDesktop(tester, [
        (
          phase: 'policy: stop window events',
          action: () async => controller.listen(null),
        ),
        (phase: 'policy: dispose presentation', action: presentation.dispose),
        (
          phase: 'policy: release native window',
          action: controller.releaseNativeWindow,
        ),
        (phase: 'policy: dispose model', action: () async => model.dispose()),
        (
          phase: 'policy: close receiver stream',
          action: backend.controller.close,
        ),
      ]),
    );
    final strings = AppLocalizationsEn();
    Future<void> update() async {
      await runDesktopPhase(
        tester,
        'window policy update: status=${model.status}, video=${model.videoWidth}x${model.videoHeight}',
        () => presentation.update(strings),
      );
      await _settleWidgets(tester);
      expect(errors, isEmpty);
    }

    await update();
    // API support does not guarantee a shell tray host is actually present
    // (for example Openbox under Xvfb). Failed registration must stay visible.
    if (Platform.isLinux && !presentation.canHide) {
      debugPrint(
        'Tray host unavailable: verifying visible-window fallback; tray interactions are not exercised',
      );
      expect(nativeWindow.isVisible, isTrue);
    } else {
      expect(presentation.canHide, native.TrayManager.instance.isSupported());
    }
    final idle = await _waitForWindow(
      tester,
      (value) => !value.fullscreen && value.aspectRatio == 0,
      reason: 'idle tray policy window',
    );
    final idleContent = idle.content;
    frame(backend, 1920, 1080);
    model.desktopOptions['alwaysOnTop'] = true;
    await update();
    await _waitForWindow(
      tester,
      (value) => value.hasRatio(16 / 9) && value.alwaysOnTop,
      reason: 'landscape video and always-on-top policy',
    );
    final landscape = nativeWindow.contentSize;
    for (var i = 0; i < 3; i++) {
      frame(backend, 1080, 1920);
      await update();
      await _waitForWindow(
        tester,
        (value) => value.hasRatio(9 / 16),
        reason: 'portrait rotation $i',
      );
      frame(backend, 1920, 1080);
      await update();
      await _waitForWindow(
        tester,
        (value) =>
            value.hasRatio(16 / 9) &&
            (value.content.width - landscape.width).abs() <= 3 &&
            (value.content.height - landscape.height).abs() <= 3,
        reason: 'landscape rotation $i preserves the fitted size',
      );
    }
    frame(backend, 640, 360);
    await update();
    await runDesktopPhase(
      tester,
      'resize to actual video pixels',
      () => presentation.resize(actualSize: true),
    );
    await _waitForWindow(
      tester,
      (value) =>
          (value.content.width * tester.view.devicePixelRatio - 640).abs() <=
              3 &&
          (value.content.height * tester.view.devicePixelRatio - 360).abs() <=
              3,
      reason: 'actual video pixel size',
    );
    await _executeWindow(tester, controller, WindowCommand.enterFullscreen);
    await _waitForWindow(
      tester,
      (value) => value.fullscreen,
      reason: 'fullscreen with always-on-top preference',
      stableFor: const Duration(seconds: 1),
    );
    await _executeWindow(tester, controller, WindowCommand.exitFullscreen);
    await _waitForWindow(
      tester,
      (value) => !value.fullscreen && value.alwaysOnTop,
      reason: 'fullscreen exit restores always-on-top',
      stableFor: const Duration(seconds: 1),
    );
    await _executeWindow(tester, controller, WindowCommand.enterFullscreen);
    await _waitForWindow(
      tester,
      (value) => value.fullscreen,
      reason: 'fullscreen before the tray-policy disconnect',
      stableFor: const Duration(seconds: 1),
    );
    backend.state('waiting');
    await update();
    await _executeWindow(tester, controller, WindowCommand.exitFullscreen);
    await _waitForWindow(
      tester,
      (value) =>
          !value.fullscreen &&
          !value.alwaysOnTop &&
          value.aspectRatio == 0 &&
          (value.content.width - idleContent.width).abs() <= 3 &&
          (value.content.height - idleContent.height).abs() <= 3,
      reason: 'fullscreen disconnect restores idle size and on-top policy',
    );
    if (presentation.canHide) {
      debugPrint('Checking close-to-tray after fullscreen restoration');
      await _executeWindow(tester, controller, WindowCommand.closeWindow);
      // Hidden desktop windows stop delivering Flutter frames. Wait for the OS
      // state without pumping, then reveal the window before further frame checks.
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (nativeWindow.isVisible && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      expect(nativeWindow.isVisible, isFalse);
      debugPrint('Checking show-on-connect and delayed hide');
      frame(backend, 1920, 1080);
      await update();
      expect(
        nativeWindow.isVisible,
        isTrue,
      ); // showOnConnect shares the same native window.
      final starts = backend.starts, stops = backend.stops;
      await _executeWindow(tester, controller, WindowCommand.closeWindow);
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (nativeWindow.isVisible && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      expect(nativeWindow.isVisible, isFalse);
      expect(model.hasVideo, isTrue);
      expect(model.status, 'streaming');
      expect(backend.starts, starts);
      expect(backend.stops, stops);
      await presentation.show();
      await presentation.hide();
      // Start another visible session to exercise automatic hiding separately.
      backend.state('waiting');
      await update();
      frame(backend, 1920, 1080);
      await update();
      media(backend);
      await update();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3200)),
      );
      expect(nativeWindow.isVisible, isFalse);
      expect(
        model.audioPlaying,
        isTrue,
      ); // Automatic hiding must not disconnect audio.
      expect(backend.stops, stops);
      await presentation.show();
      await _settleWidgets(tester);
      expect(nativeWindow.isVisible, isTrue);
      await presentation.hide();
      expect(model.audioPlaying, isTrue);
      expect(backend.stops, stops);
      await presentation.show();
      frame(backend, 1920, 1080);
      await update();
      backend.state('waiting');
      await update();
      await presentation.show();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3200)),
      );
      expect(
        nativeWindow.isVisible,
        isTrue,
      ); // User activation cancels the session's auto-hide.
      model.desktopOptions['keepInMenuBar'] = false;
      await update();
      expect(presentation.canHide, isFalse);
    }
    expect(errors, isEmpty);
  });

  testWidgets('initial iPad expansion keeps the platform event loop responsive', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: false);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final backend = FakeReceiver(
      capabilities: {
        'platform': Platform.operatingSystem,
        'nativeVideoSurface': Platform.isMacOS,
      },
    );
    final model = ReceiverModel(backend);
    const controller = WindowController();
    Timer? sampler;
    addTearDown(
      () => cleanUpDesktop(tester, [
        (phase: 'cadence: stop sampler', action: () async => sampler?.cancel()),
        (
          phase: 'cadence: unmount ReceiverApp',
          action: () => tester.pumpWidget(const SizedBox()),
        ),
        (
          phase: 'cadence: close receiver stream',
          action: backend.controller.close,
        ),
      ]),
    );
    await tester.pumpWidget(ReceiverApp(model: model, window: controller));
    await _waitForWindow(
      tester,
      (_) => model.loaded && model.status == 'waiting',
      reason: 'resize cadence startup',
    );
    await controller.withWindow((value) {
      value.show();
      value.aspectRatio = 0;
      value.contentSize = const native.Size(width: 440, height: 560);
    });
    final clock = Stopwatch()..start();
    final samples = <int>[0];
    final sizes = <native.Rectangle>[];
    int? expandedAt;
    await tester.runAsync(() async {
      sampler = Timer.periodic(const Duration(milliseconds: 8), (_) {
        samples.add(clock.elapsedMicroseconds);
        unawaited(
          controller.withWindow((value) {
            sizes.add(value.bounds);
            final size = value.contentSize;
            if (size.width > 500 &&
                (size.width / size.height - 4 / 3).abs() < .01) {
              expandedAt ??= clock.elapsedMilliseconds;
            }
          }),
        );
      });
      frame(backend, 2048, 1536);
      await Future<void>.delayed(const Duration(seconds: 2));
      sampler!.cancel();
      samples.add(clock.elapsedMicroseconds);
    });
    final gaps = [
      for (var i = 1; i < samples.length; i++)
        (samples[i] - samples[i - 1]) / 1000,
    ];
    final maximumGap = gaps.reduce((a, b) => a > b ? a : b);
    debugPrint(
      'Window expansion: max event-loop gap=${maximumGap.toStringAsFixed(1)}ms, '
      'distinct frames=${sizes.toSet().length}, target=${expandedAt}ms',
    );
    await _waitForWindow(
      tester,
      (value) => value.hasRatio(4 / 3),
      reason: 'iPad expansion target',
    );
    // Detect the one-second synchronous Flutter/AppKit resize stalls. This is
    // an event-loop regression check, not a monitor refresh-rate benchmark.
    expect(
      maximumGap,
      lessThan(200),
      reason: 'Expansion must not block video delivery on the platform thread',
    );
    if (Platform.isMacOS) {
      expect(sizes.toSet().length, greaterThan(3));
      expect(expandedAt, isNotNull);
      expect(
        expandedAt!,
        lessThan(800),
        reason: 'Empty Flutter frames must not cause native resize timeouts',
      );
    }
  });
}
