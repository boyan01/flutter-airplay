// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:ui' show isRunningOnPlatformThread;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_airplay/app/receiver_app.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_airplay/ui/playback/video_crop_editor.dart';
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
      fullscreen = window.isFullScreen;

  final native.Rectangle frame;
  final native.Size content;
  final bool fullscreen;

  bool sameFrame(_WindowGeometry other, {double tolerance = 3}) =>
      (frame.x - other.frame.x).abs() <= tolerance &&
      (frame.y - other.frame.y).abs() <= tolerance &&
      (frame.width - other.frame.width).abs() <= tolerance &&
      (frame.height - other.frame.height).abs() <= tolerance &&
      (content.width - other.content.width).abs() <= tolerance &&
      (content.height - other.content.height).abs() <= tolerance;

  @override
  String toString() =>
      'frame=(${frame.x}, ${frame.y}, ${frame.width}, ${frame.height}), '
      'content=(${content.width}, ${content.height}), '
      'fullscreen=$fullscreen';
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
        await controller.withWindow((value) {
          geometry = _WindowGeometry(value);
          lastSnapshot = '$geometry';
        });
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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Native resizes can synchronously pump engine frames. Use production-like
  // frame scheduling rather than the live test binding's pointer-fade policy.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('desktop UI crops video and enters and leaves real fullscreen', (
    tester,
  ) async {
    expect(
      isRunningOnPlatformThread,
      isTrue,
      reason: 'Desktop FFI window calls require the platform thread',
    );
    late int hostHandle;
    // Exercise hide/show before presentation registers its first listener.
    // On Windows this previously re-entered nativeapi's manager constructor
    // while seeding changed occlusion state and blocked the platform thread.
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
    final model = ReceiverModel(backend);
    await tester.pumpWidget(ReceiverApp(model: model));
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
    // Exercise the crop journey in this same app and OS window.
    frame(backend, 1200, 900);
    await _waitForWindow(
      tester,
      (value) =>
          (value.content.width / value.content.height - 4 / 3).abs() < .01,
      reason: 'uncropped video aspect',
    );
    await tester.tapAt(tester.getCenter(find.byKey(const Key('playerPage'))));
    await tester.pump(const Duration(milliseconds: 350));
    await _settleWidgets(tester);
    await tester.tap(find.byKey(const Key('cropVideo')));
    await _settleWidgets(tester);
    expect(find.byType(VideoCropEditor), findsOneWidget);
    final beforePreview = _WindowGeometry(window);
    await tester.tap(find.byKey(const Key('cropPreview')));
    await _settleWidgets(tester);
    expect(find.byKey(const Key('cropSelection')), findsNothing);
    expect(model.videoCrop, ReceiverModel.fullVideoCrop);
    expect(_WindowGeometry(window).sameFrame(beforePreview), isTrue);
    await tester.tap(
      find.descendant(
        of: find.byType(VideoCropEditor),
        matching: find.byType(FilledButton),
      ),
    );
    await _settleWidgets(tester);
    expect(find.byType(VideoCropEditor), findsNothing);
    expect(model.videoCrop, const Rect.fromLTWH(0, .125, 1, .75));
    await _waitForWindow(
      tester,
      (value) =>
          (value.content.width / value.content.height - 16 / 9).abs() < .01,
      reason: 'applied crop aspect',
    );

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
    await tester.pumpWidget(const SizedBox());
  });
}
