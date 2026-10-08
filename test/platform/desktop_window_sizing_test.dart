import 'dart:async';

// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_airplay/platform/desktop_window_sizing.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart' as native;

import 'fake_window.dart';

class Display implements native.Display {
  Display({this.scaleFactor = 1, native.Rectangle? area})
    : workArea =
          area ?? const native.Rectangle(x: 0, y: 0, width: 1600, height: 1000);
  @override
  final double scaleFactor;
  @override
  final native.Rectangle workArea;
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class NativeResizeController extends WindowController {
  NativeResizeController(this.value)
    : super(
        withWindow: (action) async => action(value),
        getDisplays: () => [Display()],
      );
  final FakeWindow value;
  final requests = <(native.Rectangle, Duration)>[];
  Completer<bool>? pending;
  int cancellations = 0;

  @override
  bool get usesNativeResize => true;

  @override
  Future<bool> resizeBounds(native.Rectangle bounds, Duration duration) {
    requests.add((bounds, duration));
    if (duration == Duration.zero) {
      value.bounds = bounds;
      return Future.value(true);
    }
    pending = Completer<bool>();
    return pending!.future;
  }

  void finish() {
    value.bounds = requests.last.$1;
    pending!.complete(true);
    pending = null;
  }

  @override
  Future<void> cancelResize() async {
    cancellations++;
    pending?.complete(false);
    pending = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeWindow window;
  late DesktopWindowSizing sizing;
  late List<native.Display> displays;
  setUp(() {
    window = FakeWindow()
      ..contentSize = const native.Size(width: 620, height: 740);
    displays = [Display()];
    sizing = DesktopWindowSizing(
      WindowController(
        withWindow: (action) async => action(window),
        getDisplays: () => displays,
      ),
      integerGeometry: true,
    );
  });
  tearDown(() => sizing.dispose());
  Future<void> video(int width, int height, {bool animation = false}) =>
      sizing.update(
        connected: true,
        width: width,
        height: height,
        reduceMotion: !animation,
      );
  Future<void> disconnect() =>
      sizing.update(connected: false, width: 0, height: 0, reduceMotion: true);
  void expectBaseline() {
    expect(window.contentSize.width, 620);
    expect(window.contentSize.height, 740);
    expect(window.position, const native.Point(x: 100, y: 100));
    expect(window.aspectRatio, 0);
  }

  test(
    'native resize submits one target and cancels obsolete orientations',
    () async {
      sizing.dispose();
      final controller = NativeResizeController(window);
      sizing = DesktopWindowSizing(controller);
      final first = video(2048, 1536, animation: true);
      while (controller.pending == null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(controller.requests, hasLength(1));
      expect(window.calls, isNot(contains('bounds')));
      final rotated = video(1536, 2048, animation: true);
      await first;
      while (controller.pending == null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(controller.cancellations, 1);
      expect(controller.requests, hasLength(2));
      expect(controller.requests.last.$2, const Duration(milliseconds: 200));
      controller.finish();
      await rotated;
      expect(
        window.contentSize.width / window.contentSize.height,
        closeTo(.75, .001),
      );
      await disconnect();
      expect(controller.requests.last.$2, Duration.zero);
      expectBaseline();
    },
  );

  test('fullscreen suspension and disposal cancel native resize', () async {
    sizing.dispose();
    final controller = NativeResizeController(window);
    sizing = DesktopWindowSizing(controller);
    final first = video(2048, 1536, animation: true);
    while (controller.pending == null) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    sizing.suspend();
    await first;
    expect(controller.cancellations, 1);
    final resumed = sizing.resume();
    while (controller.pending == null) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    sizing.dispose();
    await resumed;
    expect(controller.cancellations, 2);
  });

  for (final interruption in ['suspend', 'dispose']) {
    testWidgets(
      'native resize skips $interruption during the constraint yield',
      (tester) async {
        sizing.dispose();
        final controller = NativeResizeController(window);
        sizing = DesktopWindowSizing(controller);
        final operation = video(2048, 1536);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 8));
        expect(controller.requests, isEmpty);

        if (interruption == 'suspend') {
          sizing.suspend();
        } else {
          sizing.dispose();
        }
        await tester.pump(const Duration(milliseconds: 16));
        await operation;

        expect(controller.requests, isEmpty);
        expect(window.calls, isNot(contains('bounds')));
      },
    );
  }

  testWidgets('native resize coalesces rotation during the constraint yield', (
    tester,
  ) async {
    sizing.dispose();
    final controller = NativeResizeController(window);
    sizing = DesktopWindowSizing(controller);
    final first = video(2048, 1536);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 8));
    expect(controller.requests, isEmpty);

    final rotated = video(1536, 2048);
    await tester.pump(const Duration(milliseconds: 16));
    await first;
    await tester.pump(const Duration(milliseconds: 16));
    sizing.dispose();
    await tester.pump(const Duration(milliseconds: 16));
    await rotated;

    expect(controller.requests, hasLength(1));
    expect(window.calls.where((call) => call == 'bounds'), hasLength(1));
    expect(
      window.bounds,
      const native.Rectangle(x: 110, y: 70, width: 600, height: 800),
    );
  });

  test(
    'unrepresentable bounded integer aspect uses natural GTK minimum',
    () async {
      await video(1001, 2003);
      expect(window.minimumSize, const native.Size(width: 0, height: 0));
      expect(window.contentSize.width % 1, 0);
      expect(window.contentSize.height % 1, 0);
    },
  );
  for (final dimensions in [
    (1536, 2048),
    (2048, 1536),
    (1920, 1080),
    (1170, 2532),
    (1000, 1000),
    (99, 100),
    (1179, 2556),
  ]) {
    test(
      'minimum and X11 base preserve ${dimensions.$1}:${dimensions.$2} aspect',
      () async {
        final ratio = dimensions.$1 / dimensions.$2;
        await video(dimensions.$1, dimensions.$2);
        final minimum = window.minimumSize;
        expect(minimum.width / minimum.height, closeTo(ratio, .000001));
        // Openbox constrains dimensions above PBaseSize, while GTK constrains
        // full dimensions. Both must produce the same content geometry.
        final wmHeight =
            minimum.height + (window.contentSize.width - minimum.width) / ratio;
        expect(wmHeight, closeTo(window.contentSize.width / ratio, .000001));
        expect(minimum.width % 1, 0);
        expect(minimum.height % 1, 0);
        // Native GTK integer hints must still agree within one logical pixel.
        final roundedHeight =
            minimum.height.floor() +
            (window.contentSize.width - minimum.width.floor()) / ratio;
        expect(
          roundedHeight,
          closeTo(window.contentSize.height, 1 / ratio + 1),
        );
      },
    );
  }
  test('missing native minimum hints restore the app idle minimum', () async {
    window.minimumSize = const native.Size(width: 0, height: 0);
    await video(1170, 2532);
    await disconnect();
    expect(window.minimumSize, const native.Size(width: 360, height: 480));
    expectBaseline();
  });
  test('hidden windows defer sizing until they are shown', () async {
    window.isVisible = false;
    await video(1170, 2532);
    expectBaseline();
    window.isVisible = true;
    await sizing.resume();
    expect(window.aspectRatio, closeTo(1170 / 2532, .001));
    window.isVisible = false;
    await disconnect();
    expect(window.aspectRatio, isNot(0));
    window.isVisible = true;
    await sizing.resume();
    expectBaseline();
  });
  test(
    'records events before desktop readiness without native access',
    () async {
      sizing.dispose();
      var calls = 0;
      sizing = DesktopWindowSizing(
        WindowController(
          withWindow: (action) async {
            calls++;
            action(window);
          },
          getDisplays: () => displays,
        ),
        initiallyEnabled: false,
      );
      await video(1536, 2048);
      await disconnect();
      await video(1170, 2532);
      expect(calls, 0);
      await sizing.enable();
      expect(window.aspectRatio, closeTo(1170 / 2532, .001));
      await disconnect();
      expectBaseline();
    },
  );
  test(
    'iPad rotation and disconnect restore original size and position',
    () async {
      await video(1536, 2048);
      expect(
        window.contentSize.width / window.contentSize.height,
        closeTo(.75, .001),
      );
      await video(2048, 1536);
      expect(window.aspectRatio, closeTo(4 / 3, .001));
      await disconnect();
      expectBaseline();
    },
  );
  test(
    'same-tick disconnect and iPhone cannot inherit iPad geometry',
    () async {
      await video(2048, 1536);
      final end = disconnect();
      final next = video(1170, 2532);
      await Future.wait([end, next]);
      expect(
        window.contentSize.width / window.contentSize.height,
        closeTo(1170 / 2532, .001),
      );
      await disconnect();
      expectBaseline();
    },
  );
  test(
    'reconnect without a first frame still restores the prior session',
    () async {
      await video(2048, 1536);
      await Future.wait([disconnect(), video(0, 0)]);
      expectBaseline();
      await video(1170, 2532);
      expect(window.aspectRatio, closeTo(1170 / 2532, .001));
      await disconnect();
      expectBaseline();
    },
  );
  test(
    'first frame interrupts pending restoration without losing baseline',
    () async {
      await video(2048, 1536);
      final end = sizing.update(connected: false, width: 0, height: 0);
      final waiting = sizing.update(connected: true, width: 0, height: 0);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await video(1170, 2532);
      await Future.wait([end, waiting]);
      expect(window.aspectRatio, closeTo(1170 / 2532, .001));
      await disconnect();
      expectBaseline();
    },
  );
  test('zero video during streaming is not a session end', () async {
    await video(1536, 2048);
    final before = window.bounds;
    await video(0, 0);
    expect(window.bounds, before);
    await video(1536, 2048);
    expect(window.bounds, before);
    await disconnect();
    expectBaseline();
  });
  test(
    'rapid rotations are latest wins, including return to old ratio',
    () async {
      await video(1080, 1920);
      await Future.wait([
        video(1920, 1080),
        video(1080, 1920),
        video(2048, 1536),
      ]);
      expect(window.aspectRatio, closeTo(4 / 3, .001));
      expect(
        window.contentSize.width / window.contentSize.height,
        closeTo(4 / 3, .001),
      );
    },
  );
  test('fullscreen disconnect is deferred until returning to normal', () async {
    await video(2048, 1536);
    final before = window.bounds;
    window.fullscreen = true;
    await disconnect();
    expect(window.bounds, before);
    window.fullscreen = false;
    await sizing.resume();
    expectBaseline();
  });
  test(
    'transition, maximize and minimize retain the latest desired ratio',
    () async {
      await video(1080, 1920);
      sizing.suspend();
      await video(2048, 1536);
      window.maximized = true;
      await sizing.resume();
      expect(window.aspectRatio, closeTo(9 / 16, .001));
      window.maximized = false;
      window.minimized = true;
      await sizing.resume();
      window.minimized = false;
      await sizing.resume();
      expect(window.aspectRatio, closeTo(4 / 3, .001));
    },
  );
  test(
    'manual scale survives same-ratio resolution updates and rotation',
    () async {
      await video(1080, 1920);
      window.contentSize = const native.Size(width: 270, height: 480);
      await sizing.observeWindow();
      await video(540, 960);
      expect(window.contentSize, const native.Size(width: 270, height: 480));
      await video(1920, 1080);
      expect(window.contentSize.width, closeTo(480, .01));
      expect(window.contentSize.height, closeTo(270, .01));
    },
  );
  test('moving a window does not opt out of automatic fit', () async {
    await video(1080, 1920);
    window.position = const native.Point(x: 350, y: 20);
    await sizing.observeWindow();
    await video(1920, 1080);
    expect(window.contentSize.width, closeTo(1280, .01));
    expect(window.contentSize.height, closeTo(720, .01));
  });
  test('reduced motion uses one atomic final frame write', () async {
    await video(1170, 2532);
    expect(window.calls.where((call) => call == 'bounds'), hasLength(1));
  });
  test(
    'new request cancels an active animation without stale final writes',
    () async {
      final first = video(2048, 1536, animation: true);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await video(1170, 2532);
      await first;
      expect(window.aspectRatio, closeTo(1170 / 2532, .001));
      await disconnect();
      expectBaseline();
    },
  );
  test(
    'identical updates during animation do not cancel its progress',
    () async {
      final first = video(2048, 1536, animation: true);
      final repeats = <Future<void>>[];
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        repeats.add(video(2048, 1536, animation: true));
      }
      await Future.wait([first, ...repeats]);
      expect(window.aspectRatio, closeTo(4 / 3, .001));
      expect(
        window.contentSize.width / window.contentSize.height,
        closeTo(4 / 3, .001),
      );
      expect(
        window.calls.where((call) => call == 'bounds').length,
        greaterThan(2),
      );
    },
  );
  test('dispose cancels animation and prevents later writes', () async {
    final first = video(2048, 1536, animation: true);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    sizing.dispose();
    final count = window.calls.length;
    await first;
    expect(window.calls, hasLength(count));
  });
  test('an unchanged request can retry a failed native operation', () async {
    sizing.dispose();
    var fail = true;
    sizing = DesktopWindowSizing(
      WindowController(
        withWindow: (action) async {
          if (fail) throw PlatformException(code: 'temporary_window_failure');
          action(window);
        },
        getDisplays: () => displays,
      ),
    );
    await expectLater(video(1170, 2532), throwsA(isA<PlatformException>()));
    fail = false;
    await video(1170, 2532);
    expect(window.aspectRatio, closeTo(1170 / 2532, .001));
  });
  test(
    'tiny work areas lower minimums rather than violating video ratio',
    () async {
      displays = [
        Display(
          area: const native.Rectangle(x: 0, y: 0, width: 160, height: 120),
        ),
      ];
      await video(1170, 2532);
      expect(
        window.minimumSize.width,
        lessThanOrEqualTo(window.size.width + .001),
      );
      expect(
        window.minimumSize.height,
        lessThanOrEqualTo(window.size.height + .001),
      );
      expect(
        window.contentSize.width / window.contentSize.height,
        closeTo(1170 / 2532, .02),
      );
      await disconnect();
      expect(window.size.width, lessThanOrEqualTo(160));
      expect(window.size.height, lessThanOrEqualTo(120));
    },
  );
  test('fit and actual pixels respect monitor DPI and work area', () async {
    displays = [
      Display(
        scaleFactor: 2,
        area: const native.Rectangle(x: -1600, y: 0, width: 1600, height: 1000),
      ),
    ];
    window.position = const native.Point(x: -1000, y: 100);
    await video(640, 360);
    await sizing.fit(actualSize: true);
    expect(window.contentSize, const native.Size(width: 320, height: 180));
    expect(window.position.x, greaterThanOrEqualTo(-1600));
    expect(window.position.x + window.size.width, lessThanOrEqualTo(0));
  });
  test(
    'late native configure cannot overwrite the final restored rectangle',
    () async {
      final nativeWindow = LateConfigureWindow()
        ..contentSize = const native.Size(width: 620, height: 740);
      window = nativeWindow;
      addTearDown(nativeWindow.cancel);
      await video(2048, 1536);
      nativeWindow.requests.clear();
      nativeWindow.disturbNext = true;
      await disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expectBaseline();
      expect(nativeWindow.requests, hasLength(2));
      expect(nativeWindow.requests[0], nativeWindow.requests[1]);
    },
  );
  test('new revision cancels an old final-target correction', () async {
    final nativeWindow = LateConfigureWindow()
      ..contentSize = const native.Size(width: 620, height: 740);
    window = nativeWindow;
    addTearDown(nativeWindow.cancel);
    await video(2048, 1536);
    nativeWindow.requests.clear();
    nativeWindow.disturbNext = true;
    final restoring = disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    await video(1170, 2532);
    await restoring;
    expect(
      nativeWindow.requests.where((r) => r.width == 620 && r.height == 740),
      hasLength(1),
    );
    expect(window.aspectRatio, closeTo(1170 / 2532, .001));
    await disconnect();
    expectBaseline();
  });
  for (final state in ['hidden', 'maximized']) {
    test('$state window cancels pending final-target correction', () async {
      final nativeWindow = LateConfigureWindow()
        ..contentSize = const native.Size(width: 620, height: 740);
      window = nativeWindow;
      addTearDown(nativeWindow.cancel);
      await video(2048, 1536);
      nativeWindow.requests.clear();
      nativeWindow.disturbNext = true;
      final restoring = disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      if (state == 'hidden') window.isVisible = false;
      if (state == 'maximized') window.maximized = true;
      await restoring;
      expect(nativeWindow.requests, hasLength(1));
    });
  }
  test(
    'a real native refusal still fails after one bounded correction',
    () async {
      final nativeWindow = LateConfigureWindow()
        ..contentSize = const native.Size(width: 620, height: 740);
      window = nativeWindow;
      await video(2048, 1536);
      nativeWindow.requests.clear();
      nativeWindow.reject = true;
      await expectLater(
        disconnect(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'window_resize_failed',
          ),
        ),
      );
      expect(nativeWindow.requests, hasLength(2));
    },
  );
}

/// Models a late native configure that overwrites an acknowledged frame.
/// Writes are recorded separately from the simulated OS event.
class LateConfigureWindow extends FakeWindow {
  final requests = <native.Rectangle>[];
  bool disturbNext = false, reject = false;
  Timer? _lateConfigure;
  @override
  set bounds(native.Rectangle value) {
    requests.add(value);
    super.bounds = value;
    final displaced = native.Rectangle(
      x: value.x,
      y: value.y,
      width: value.width + 54,
      height: value.height,
    );
    if (reject) {
      _configure(displaced);
    } else if (disturbNext) {
      disturbNext = false;
      _lateConfigure = Timer(
        const Duration(milliseconds: 40),
        () => _configure(displaced),
      );
    }
  }

  void _configure(native.Rectangle value) => super.bounds = value;
  void cancel() => _lateConfigure?.cancel();
}
