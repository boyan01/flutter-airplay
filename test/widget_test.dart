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
  Map<String, bool> savedOptions = {};
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
    savedOptions = Map.of(desktopOptions);
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
        'supportsLaunchAtLogin': platform == 'windows',
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

  void media(FakeReceiver backend, {bool audio = true, bool paused = false}) {
    backend.state('streaming');
    backend.controller.add({
      'type': 'media',
      'audioPlaying': audio,
      'videoPaused': paused,
    });
    backend.controller.add({
      'type': 'video',
      'textureId': 0,
      'videoWidth': 0,
      'videoHeight': 0,
    });
  }

  testWidgets('Audio and sender pause have their own page until a new frame', (
    tester,
  ) async {
    final backend = await launch(tester, platform: 'android');
    backend.controller.add({'type': 'client', 'name': 'Alice’s iPhone'});
    backend.state('streaming');
    await tester.pump();
    expect(find.text('Alice’s iPhone 正在连接…'), findsOneWidget);
    media(backend);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audioPage')), findsOneWidget);
    expect(find.text('音频播放中'), findsOneWidget);
    expect(find.text('已连接 · Alice’s iPhone'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('homeInstructions')), findsNothing);
    frame(backend);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playerPage')), findsOneWidget);
    media(backend, paused: true);
    await tester.pumpAndSettle();
    expect(find.text('画面已暂停'), findsOneWidget);
    expect(find.text('音频仍在播放'), findsOneWidget);
    expect(find.text('亮屏并继续屏幕镜像，画面会自动恢复。'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(backend.stops, 0);
    frame(backend);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audioPage')), findsNothing);
    expect(find.byKey(const Key('playerPage')), findsOneWidget);
  });

  testWidgets(
    'Paused TV keeps its connection and supports explicit D-pad disconnect',
    (tester) async {
      final backend = await launch(
        tester,
        platform: 'android',
        tv: true,
        size: const Size(960, 540),
      );
      frame(backend);
      await tester.pumpAndSettle();
      media(backend, paused: true);
      await tester.pumpAndSettle();
      expect(find.text('投屏已结束'), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('openSettings')))
            .focusNode
            ?.hasFocus,
        true,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(backend.stops, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(backend.stops, 1);
      expect(backend.starts, 2);
      expect(find.text('可被发现'), findsOneWidget);
    },
  );

  for (final locale in ['zh', 'en']) {
    testWidgets(
      '$locale audio page fits small windows, large text and landscape',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final backend = await launch(
          tester,
          locale: locale,
          size: const Size(390, 560),
        );
        media(backend, paused: true);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('macWindowBar')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.binding.setSurfaceSize(const Size(700, 390));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const Key('disconnect')));
        await tester.tap(find.byKey(const Key('disconnect')));
        await tester.pumpAndSettle();
        expect(backend.stops, 1);
      },
    );
  }

  test(
    'Media flags survive snapshots, fresh frames and clear on session end',
    () async {
      final backend = FakeReceiver(autoStart: false);
      final model = ReceiverModel(backend);
      await model.initialize();
      final snapshot = await backend.snapshot();
      snapshot.addAll({
        'status': 'streaming',
        'audioPlaying': true,
        'videoPaused': true,
      });
      backend.controller.add({'type': 'snapshot', 'data': snapshot});
      expect(model.showAudioPage, true);
      frame(backend);
      expect(model.videoPaused, false);
      expect(model.audioPlaying, true);
      expect(model.showAudioPage, false);
      for (final status in ['stopping', 'stopped', 'error', 'waiting']) {
        media(backend, paused: true);
        backend.state(status);
        expect(model.audioPlaying, false);
        expect(model.videoPaused, false);
        expect(model.showAudioPage, false);
      }
      model.dispose();
      await backend.controller.close();
    },
  );

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

  testWidgets('Android system permission entries preserve reception', (
    tester,
  ) async {
    const window = MethodChannel('org.flutterairplay/window');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(window, (
      call,
    ) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        window,
        null,
      ),
    );
    final backend = await launch(tester, platform: 'android');
    expect(find.text('退到后台后仍可接收投屏'), findsOneWidget);
    await tester.tap(find.byTooltip('修改设备名'));
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('backgroundLaunch'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(calls, contains('requestBackgroundLaunch'));
    final permissions = find.byKey(const Key('appPermissions'));
    await tester.ensureVisible(permissions);
    await tester.tap(permissions);
    await tester.pumpAndSettle();
    expect(calls, contains('openAppSettings'));
    expect(backend.stops, 0);
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
  testWidgets(
    'iPad uses mobile controls and states its foreground constraint',
    (tester) async {
      final backend = await launch(
        tester,
        platform: 'ios',
        size: const Size(1024, 768),
      );
      expect(find.byKey(const Key('homeToolbar')), findsOneWidget);
      expect(find.text('在 iPad 上接收镜像时，请保持应用在前台。'), findsOneWidget);
      expect(find.byKey(const Key('macWindowBar')), findsNothing);
      frame(backend);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playerPage')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const Key('playerBack')), findsOneWidget);
      expect(find.byKey(const Key('windowClose')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in ['windows', 'linux']) {
    testWidgets('$platform player uses supported desktop controls', (
      tester,
    ) async {
      const channel = MethodChannel('org.flutterairplay/window');
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final backend = await launch(tester, platform: platform);
      expect(find.text('声音由本设备播放 · 不支持 DRM 内容'), findsOneWidget);
      frame(backend);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playerPage')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const Key('macWindowBar')), findsNothing);
      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.byKey(Key('${platform}WindowBar')), findsOneWidget);
      await tester.tap(find.byIcon(Icons.fullscreen));
      expect(calls, contains('toggleFullscreen'));
      expect(tester.takeException(), isNull);
    });
  }
  for (final platform in ['windows', 'linux']) {
    testWidgets(
      '$platform caption uses native window operations and preserves desktop preferences',
      (tester) async {
        const channel = MethodChannel('org.flutterairplay/window');
        const dragChannel = MethodChannel('window_manager');
        final calls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          dragChannel,
          (call) async {
            calls.add(call.method);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            dragChannel,
            null,
          ),
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call.method);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final backend = await launch(tester, platform: platform);
        expect(find.byKey(Key('${platform}WindowBar')), findsOneWidget);
        expect(find.byKey(const Key('macWindowBar')), findsNothing);
        calls.clear();
        await tester.tap(find.byKey(const Key('windowMinimize')));
        await tester.tap(find.byKey(const Key('windowMaximize')));
        await tester.tap(find.byKey(const Key('windowClose')));
        final title = find.byKey(const Key('windowDragArea'));
        await tester.tap(title);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tap(title);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.drag(title, const Offset(40, 0));
        expect(calls, [
          'minimizeWindow',
          'toggleMaximize',
          'closeWindow',
          'toggleMaximize',
          'startDragging',
        ]);
        await tester.tap(find.byKey(const Key('openSettings')));
        await tester.pumpAndSettle();
        expect(find.text('关闭窗口后保留在托盘'), findsOneWidget);
        expect(find.text('登录启动需要 macOS 13 或更新版本'), findsNothing);
        expect(
          tester
              .widget<SwitchListTile>(find.byKey(const Key('launchAtLogin')))
              .onChanged,
          platform == 'windows' ? isNotNull : isNull,
        );
        for (final key in [
          'keepInMenuBar',
          'showOnConnect',
          'fullscreenOnConnect',
          'alwaysOnTop',
        ]) {
          await tester.ensureVisible(find.byKey(Key(key)));
          await tester.tap(find.byKey(Key(key)));
          await tester.pump();
        }
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        expect(backend.savedOptions, containsPair('keepInMenuBar', false));
        expect(backend.savedOptions, containsPair('showOnConnect', false));
        expect(backend.savedOptions, containsPair('fullscreenOnConnect', true));
        expect(backend.savedOptions, containsPair('alwaysOnTop', true));
        expect(backend.stops, 0);
        expect(backend.starts, 1);
      },
    );

    testWidgets(
      '$platform keyboard shortcuts control reception and fullscreen',
      (tester) async {
        const channel = MethodChannel('org.flutterairplay/window');
        final calls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call.method);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final backend = await launch(tester, platform: platform);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(backend.stops, 1);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(backend.starts, 2);
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        expect(calls, contains('toggleFullscreen'));
      },
    );
    testWidgets(
      '$platform tray actions reuse reception and update window state',
      (tester) async {
        const channel = MethodChannel('org.flutterairplay/window');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final backend = await launch(tester, platform: platform);
        Future<void> nativeCall(String method, [Object? arguments]) async {
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, arguments),
            ),
            (_) {},
          );
          await tester.pumpAndSettle();
        }

        await nativeCall('windowStateChanged', {
          'maximized': true,
          'fullscreen': false,
        });
        expect(find.byTooltip('还原'), findsOneWidget);
        await nativeCall('toggleReceiver');
        expect(backend.stops, 1);
        await nativeCall('toggleReceiver');
        expect(backend.starts, 2);
        frame(backend);
        await tester.pumpAndSettle();
        await nativeCall('toggleOnTop');
        expect(backend.savedOptions, containsPair('alwaysOnTop', true));
        expect(backend.stops, 1);
        await nativeCall('disconnectSession');
        expect(backend.stops, 2);
        expect(backend.starts, 3);
        expect(find.byKey(const Key('playerPage')), findsNothing);
        expect(find.byKey(Key('${platform}WindowBar')), findsOneWidget);
      },
    );
  }
}
