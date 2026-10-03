import 'dart:async';

import 'package:flutter_airplay/main.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_airplay/receiver/receiver_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixin_logger/mixin_logger.dart' as logging;

class FakeReceiver implements ReceiverRepository {
  FakeReceiver({
    this.autoStart = true,
    this.capabilities = const {
      'platform': 'macos',
      'supportsExecutablePath': true,
    },
  });
  bool autoStart;
  final Map<String, dynamic>? capabilities;
  final controller = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  int starts = 0, stops = 0;
  String? startedName, savedName, failure;
  Completer<void>? startup;
  Completer<void>? shutdown;
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  Future<Map<String, dynamic>> snapshot() async => {
    'autoStart': autoStart,
    'status': 'stopped',
    'message': '接收器未启动',
    'pid': 0,
    'name': 'Flutter AirPlay',
    'path': '',
    'logs': <dynamic>[],
    if (capabilities != null) 'capabilities': capabilities,
  };
  void state(String status, [int pid = 42]) => controller.add({
    'type': 'state',
    'status': status,
    'message': status,
    'pid': pid,
  });
  @override
  Future<void> start(String name, String path) async {
    starts++;
    startedName = name;
    if (failure != null) {
      throw PlatformException(code: 'receiver_error', message: failure);
    }
    state('starting');
    if (startup != null) await startup!.future;
    state('waiting');
  }

  @override
  Future<void> stop() async {
    stops++;
    if (shutdown != null) {
      state('stopping');
      await shutdown!.future;
    }
    state('stopped', 0);
  }

  @override
  Future<void> save(
    String name,
    String path, {
    bool autoStart = true,
    Map<String, bool> desktopOptions = const {},
  }) async {
    this.autoStart = autoStart;
    savedName = name;
  }

  @override
  Future<void> check(String path) async {
    if (failure != null) {
      throw PlatformException(code: 'receiver_error', message: failure);
    }
  }
}

void main() {
  test(
    'Receiver logs persist once across snapshots, clearing and UI trimming',
    () async {
      final written = <String>[];
      final previous = logging.onWriteToFile;
      logging.onWriteToFile = written.add;
      final backend = FakeReceiver(autoStart: false);
      final model = ReceiverModel(backend);
      addTearDown(() async {
        model.dispose();
        await backend.controller.close();
        logging.onWriteToFile = previous;
      });
      await model.initialize();
      written.clear();
      Map<String, dynamic> entry(int id) => {
        'id': id,
        'time': '2026-01-01T00:00:00Z',
        'text': 'Synthetic log $id',
      };
      final snapshot = await backend.snapshot();
      snapshot['logs'] = [entry(1), entry(2)];
      backend.controller.add({'type': 'snapshot', 'data': snapshot});
      backend.controller.add({'type': 'log', 'entry': entry(2)});
      model.clearLogs();
      backend.controller.add({'type': 'snapshot', 'data': snapshot});
      for (var id = 3; id <= 305; id++) {
        backend.controller.add({'type': 'log', 'entry': entry(id)});
      }
      expect(written.length, 305);
      expect(written.first, contains('Synthetic log 1'));
      expect(written.last, contains('Synthetic log 305'));
      expect(model.logs.length, 300);
    },
  );

  Future<FakeReceiver> launch(
    WidgetTester tester, {
    Size size = const Size(440, 650),
    String platform = 'macos',
    bool tv = false,
    bool autoStart = true,
    String locale = 'zh',
    FakeReceiver? backend,
  }) async {
    await tester.binding.setSurfaceSize(size);
    tester.platformDispatcher.localesTestValue = [Locale(locale)];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
      tester.platformDispatcher.clearLocalesTestValue();
    });
    backend ??= FakeReceiver(
      autoStart: autoStart,
      capabilities: {
        'platform': platform,
        'isTelevision': tv,
        'supportsExecutablePath': platform == 'macos',
      },
    );
    await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
    await tester.pumpAndSettle();
    addTearDown(backend.controller.close);
    return backend;
  }

  void frame(FakeReceiver backend, [int width = 160, int height = 90]) {
    backend.state('streaming');
    backend.controller.add({
      'type': 'video',
      'textureId': 0,
      'videoWidth': width,
      'videoHeight': height,
    });
  }

  testWidgets('Launch automatically receives without an idle preview', (
    tester,
  ) async {
    final backend = await launch(tester);
    expect(backend.starts, 1);
    expect(find.text('可被发现 · 等待 iPhone'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
    expect(find.byKey(const Key('appearance')), findsNothing);
    await tester.tap(find.byKey(const Key('receiveSwitch')));
    await tester.pumpAndSettle();
    expect(backend.stops, 1);
    expect(find.text('接收已关闭 · 不会被发现'), findsOneWidget);
  });

  testWidgets('All home states render and command errors offer recovery', (
    tester,
  ) async {
    final backend = await launch(tester, autoStart: false);
    for (final entry in {
      'stopped': '接收已关闭 · 不会被发现',
      'checking': '正在启动…',
      'starting': '正在启动…',
      'waiting': '可被发现 · 等待 iPhone',
      'streaming': 'iPhone 正在连接…',
      'stopping': '正在停止…',
      'error': '无法接收投屏',
    }.entries) {
      backend.state(entry.key);
      await tester.pump();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
    }
    backend.failure = '端口被占用';
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('端口被占用'), findsOneWidget);
    expect(find.text('检查环境'), findsOneWidget);
    expect(find.text('查看日志'), findsOneWidget);
  });

  testWidgets('Rename while receiving stops, saves and resumes', (
    tester,
  ) async {
    final backend = await launch(tester);
    await tester.tap(find.byTooltip('修改设备名'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const Key('receiverName'))).enabled,
      true,
    );
    await tester.enterText(
      find.byKey(const Key('receiverName')),
      'Living Room',
    );
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(backend.savedName, 'Living Room');
    expect(backend.startedName, 'Living Room');
    expect(backend.starts, 2);
    expect(backend.stops, 1);
  });

  testWidgets(
    'Auto receive preference is saved without interrupting playback',
    (tester) async {
      final backend = await launch(tester);
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('autoStart')));
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(backend.autoStart, false);
      expect(backend.stops, 0);
    },
  );

  testWidgets('Blank names and cancel preserve saved values', (tester) async {
    final backend = await launch(tester, autoStart: false);
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('receiverName')), '   ');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('请输入设备名'), findsOneWidget);
    expect(backend.savedName, isNull);
    expect(backend.starts, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Home action');
  });

  testWidgets(
    'First frame opens clean player, rotation preserves ratio, disconnect resumes',
    (tester) async {
      final backend = await launch(tester);
      frame(backend);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('playerPage')), findsOneWidget);
      expect(find.byKey(const Key('playerControls')), findsNothing);
      expect(find.byKey(const Key('openSettings')), findsNothing);
      frame(backend, 90, 160);
      await tester.pumpAndSettle();
      expect(
        tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
        90 / 160,
      );
      await tester.tap(find.byKey(const Key('playerPage')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('disconnect')));
      await tester.pumpAndSettle();
      expect(find.byType(Texture), findsNothing);
      expect(find.text('可被发现 · 等待 iPhone'), findsOneWidget);
      expect(backend.stops, 1);
      expect(backend.starts, 2);
    },
  );

  testWidgets(
    'Phone Back hides controls then requires a double Back to disconnect',
    (tester) async {
      final backend = await launch(
        tester,
        platform: 'android',
        size: const Size(390, 700),
      );
      frame(backend);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playerPage')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('playerControls')), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('再次返回将断开投屏'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(backend.stops, 1);
      expect(backend.starts, 2);
    },
  );

  testWidgets('TV defaults to Settings and Back never disconnects', (
    tester,
  ) async {
    final backend = await launch(
      tester,
      platform: 'android',
      tv: true,
      size: const Size(960, 540),
    );
    final button = tester.widget<OutlinedButton>(
      find.byKey(const Key('openSettings')),
    );
    expect(button.focusNode?.hasFocus, true);
    expect(
      tester.getRect(find.byKey(const Key('openLogs'))).bottom,
      lessThanOrEqualTo(492),
    );
    expect(
      Theme.of(tester.element(find.byKey(const Key('openSettings'))))
          .brightness,
      Brightness.dark,
    );
    frame(backend);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Continue watching');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playerControls')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playerControls')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playerControls')), findsNothing);
    expect(backend.stops, 0);
  });

  testWidgets('TV off and error put focus on the recovery action', (
    tester,
  ) async {
    final backend = await launch(
      tester,
      platform: 'android',
      tv: true,
      autoStart: false,
      size: const Size(960, 540),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('start')))
          .focusNode
          ?.hasFocus,
      true,
    );
    backend.state('error');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('start')))
          .focusNode
          ?.hasFocus,
      true,
    );
  });

  testWidgets('TV settings are a route with a separate device-name editor', (
    tester,
  ) async {
    await launch(
      tester,
      platform: 'android',
      tv: true,
      size: const Size(960, 540),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('设备名'), findsOneWidget);
    await tester.tap(find.text('设备名'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('receiverName')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['en', 'zh']) {
    testWidgets(
      '$locale small window, scaled text and settings have no overflow',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await launch(tester, locale: locale, size: const Size(390, 560));
        expect(
          find.text(
            locale == 'en'
                ? 'Discoverable · Waiting for iPhone'
                : '可被发现 · 等待 iPhone',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('openSettings')));
        await tester.pumpAndSettle();
        expect(
          find.text(locale == 'en' ? 'Device name' : '设备名'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('System locale changes update UI without restarting reception', (
    tester,
  ) async {
    final backend = await launch(tester, locale: 'zh');
    tester.platformDispatcher.localesTestValue = const [Locale('en')];
    await tester.pumpAndSettle();
    expect(find.text('Discoverable · Waiting for iPhone'), findsOneWidget);
    expect(backend.starts, 1);
  });

  test(
    'In-flight starts are ignored and save waits for asynchronous stop',
    () async {
      final backend = FakeReceiver(autoStart: false)
        ..startup = Completer<void>();
      final model = ReceiverModel(backend);
      await model.initialize();
      final first = model.start('Office', '');
      await model.start('Office', '');
      expect(backend.starts, 1);
      backend.startup!.complete();
      await first;
      await model.save('Room', '');
      expect(backend.stops, 1);
      expect(backend.savedName, 'Room');
      expect(backend.startedName, 'Room');
      model.dispose();
      await backend.controller.close();
    },
  );

  test('Video is cleared by stopping, errors and waiting', () async {
    final backend = FakeReceiver(autoStart: false);
    final model = ReceiverModel(backend);
    await model.initialize();
    for (final status in ['stopping', 'stopped', 'error', 'waiting']) {
      frame(backend);
      expect(model.hasVideo, true);
      backend.state(status);
      expect(model.hasVideo, false);
    }
    model.dispose();
    await backend.controller.close();
  });

  test('Logs remain bounded and names use UTF-8 limits', () async {
    final backend = FakeReceiver(autoStart: false);
    final model = ReceiverModel(backend);
    await model.initialize();
    for (var id = 0; id < 350; id++) {
      backend.controller.add({
        'type': 'log',
        'entry': {'id': id, 'time': '', 'text': '$id'},
      });
    }
    expect(model.logs.length, 300);
    expect(model.logs.first.id, 50);
    expect(model.validateName('接收器'), isNull);
    expect(model.validateName(List.filled(17, '器').join()), 'nameInvalid');
    expect(model.validateName('Room\nTwo'), 'nameInvalid');
    model.clearLogs();
    expect(model.logs, isEmpty);
    model.dispose();
    await backend.controller.close();
  });
  test(
    'Rename waits until the stop event, not just the stop request',
    () async {
      final backend = FakeReceiver()..shutdown = Completer<void>();
      final model = ReceiverModel(backend);
      await model.initialize();
      final saving = model.save('New Name', '');
      await Future<void>.delayed(Duration.zero);
      expect(backend.stops, 1);
      expect(backend.savedName, isNull);
      expect(backend.starts, 1);
      backend.shutdown!.complete();
      await saving;
      expect(backend.savedName, 'New Name');
      expect(backend.starts, 2);
      model.dispose();
      await backend.controller.close();
    },
  );

  testWidgets('Settings log entry opens the existing log panel', (
    tester,
  ) async {
    await launch(tester, platform: 'android');
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('接收日志'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('复制日志'), findsOneWidget);
  });
  testWidgets('TV D-pad can select disconnect explicitly', (tester) async {
    final backend = await launch(
      tester,
      platform: 'android',
      tv: true,
      size: const Size(960, 540),
    );
    frame(backend);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(backend.stops, 1);
    expect(backend.starts, 2);
  });
  testWidgets('Phone toolbar and switch stay at screen edges after rotation', (
    tester,
  ) async {
    await launch(tester, platform: 'android', size: const Size(390, 700));
    expect(tester.getRect(find.byKey(const Key('homeToolbar'))).top, 0);
    expect(tester.getRect(find.byKey(const Key('homeFooter'))).bottom, 680);
    await tester.binding.setSurfaceSize(const Size(700, 390));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const Key('homeToolbar'))).top, 0);
    expect(tester.getRect(find.byKey(const Key('homeFooter'))).bottom, 370);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'TV name confirmation saves immediately and returns to settings',
    (tester) async {
      final backend = await launch(
        tester,
        platform: 'android',
        tv: true,
        size: const Size(960, 540),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tvName')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('receiverName')),
        'Living Room',
      );
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(backend.savedName, 'Living Room');
      expect(backend.stops, 1);
      expect(backend.starts, 2);
      expect(find.byKey(const Key('tvName')), findsOneWidget);
      expect(find.text('完成'), findsNothing);
    },
  );

  testWidgets('Sender connection stays on home until a video frame exists', (
    tester,
  ) async {
    final backend = await launch(tester, platform: 'android');
    backend.controller.add({'type': 'client', 'name': 'Alice’s iPhone'});
    backend.state('streaming');
    await tester.pump();
    expect(find.byKey(const Key('playerPage')), findsNothing);
    expect(find.textContaining('Alice’s iPhone'), findsOneWidget);
    frame(backend);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('playerPage')));
    await tester.pumpAndSettle();
    expect(find.text('Alice’s iPhone'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playerControls')), findsNothing);
  });
  testWidgets('Missing sender name falls back to iPhone', (tester) async {
    final backend = await launch(tester, platform: 'android');
    backend.controller.add({'type': 'client', 'name': '  '});
    backend.state('streaming');
    await tester.pump();
    expect(find.text('iPhone 正在连接…'), findsOneWidget);
  });
  testWidgets(
    'Flutter window controls and double tap invoke native operations',
    (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('org.flutterairplay/window');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await launch(tester);
      expect(find.byKey(const Key('macWindowBar')), findsOneWidget);
      calls.clear();
      await tester.tap(find.byKey(const Key('windowClose')));
      await tester.tap(find.byKey(const Key('windowMinimize')));
      await tester.tap(find.byKey(const Key('windowFullscreen')));
      final title = find.byKey(const Key('windowDragArea'));
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 350));
      expect(calls.map((call) => call.method), [
        'closeWindow',
        'minimizeWindow',
        'toggleFullscreen',
        'toggleFullscreen',
      ]);
    },
  );

  testWidgets('macOS player window buttons hide with playback overlay', (
    tester,
  ) async {
    final backend = await launch(tester, size: const Size(200, 480));
    frame(backend);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('macWindowBar')), findsNothing);
    await tester.tap(find.byKey(const Key('playerPage')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('windowClose')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 2500));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('macWindowBar')), findsNothing);
  });
}
