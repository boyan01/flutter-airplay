import 'dart:async';

import 'package:flutter_airplay/main.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_airplay/receiver/receiver_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeReceiver implements ReceiverRepository {
  FakeReceiver({
    this.capabilities = const {
      'platform': 'macos',
      'supportsExecutablePath': true,
    },
  });
  final Map<String, dynamic>? capabilities;
  final controller = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  int starts = 0, stops = 0;
  String? startedName, savedName, failure;
  Completer<void>? startup;
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  Future<Map<String, dynamic>> snapshot() async => {
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
    state('stopped', 0);
  }

  @override
  Future<void> save(String name, String path) async {
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
  Future<void> screen(
    WidgetTester tester, [
    Size size = const Size(1000, 800),
  ]) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('Name, start, streaming, stop and restart', (tester) async {
    await screen(tester);
    final backend = FakeReceiver();
    await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('videoPreview')), findsOneWidget);
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.enterText(
      find.byKey(const Key('receiverName')),
      'Living Room',
    );
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(backend.savedName, 'Living Room');
    await tester.tap(find.byKey(const Key('start')));
    await tester.pumpAndSettle();
    expect(backend.startedName, 'Living Room');
    expect(find.text('等待连接'), findsOneWidget);
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const Key('receiverName'))).enabled,
      false,
    );
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    backend.state('streaming');
    await tester.pumpAndSettle();
    expect(find.text('已连接'), findsOneWidget);
    await tester.tap(find.byKey(const Key('stop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start')));
    await tester.pumpAndSettle();
    expect(backend.starts, 2);
    expect(backend.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dependency failure is actionable and retry remains available', (
    tester,
  ) async {
    await screen(tester);
    final backend = FakeReceiver()..failure = '缺少 GStreamer。请安装 gstreamer。';
    await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start')));
    await tester.pumpAndSettle();
    expect(find.text(backend.failure!), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('start'))).onPressed,
      isNotNull,
    );
  });

  testWidgets('Blank name never launches', (tester) async {
    await screen(tester);
    final backend = FakeReceiver();
    await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('receiverName')), '   ');
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.text('请输入设备名'), findsOneWidget);
    expect(backend.starts, 0);
  });

  testWidgets('Minimum window has no overflow', (tester) async {
    await screen(tester, const Size(760, 650));
    await tester.pumpWidget(ReceiverApp(model: ReceiverModel(FakeReceiver())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('start')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'Duplicate starts are ignored during an in-flight native command',
    () async {
      final backend = FakeReceiver()..startup = Completer<void>();
      final model = ReceiverModel(backend);
      await model.initialize();
      final first = model.start('Office', '');
      await model.start('Office', '');
      expect(backend.starts, 1);
      backend.startup!.complete();
      await first;
      expect(model.status, 'waiting');
      model.dispose();
      await backend.controller.close();
    },
  );

  test('Logs are bounded, deduplicated and clearable', () async {
    final backend = FakeReceiver();
    final model = ReceiverModel(backend);
    await model.initialize();
    for (var id = 0; id < 350; id++) {
      backend.controller.add({
        'type': 'log',
        'entry': {'id': id, 'time': '2026-10-03T12:00:00Z', 'text': '$id'},
      });
    }
    backend.controller.add({
      'type': 'log',
      'entry': {'id': 349, 'time': '', 'text': 'duplicate'},
    });
    expect(model.logs.length, 300);
    expect(model.logs.first.id, 50);
    expect(model.logs.last.text, '349');
    model.clearLogs();
    expect(model.logs, isEmpty);
    model.dispose();
    await backend.controller.close();
  });

  test('UTF-8 length and control characters are validated', () {
    final model = ReceiverModel(FakeReceiver());
    expect(model.validateName('接收器'), isNull);
    expect(model.validateName(List.filled(17, '器').join()), isNotNull);
    expect(model.validateName('Room\nTwo'), isNotNull);
    model.dispose();
  });
  testWidgets('Video dimensions, rotation, full preview and disconnect clear', (
    tester,
  ) async {
    await screen(tester);
    final backend = FakeReceiver();
    await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
    await tester.pumpAndSettle();
    backend.state('streaming');
    await tester.pumpAndSettle();
    expect(find.byType(Texture), findsNothing);
    void frame(int width, int height) => backend.controller.add({
      'type': 'video',
      'textureId': 0,
      'videoWidth': width,
      'videoHeight': height,
    });
    frame(160, 90);
    await tester.pumpAndSettle();
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 0);
    await tester.ensureVisible(find.byKey(const Key('expandPreview')));
    await tester.tap(find.byKey(const Key('expandPreview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('collapsePreview')), findsOneWidget);
    frame(90, 160);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AspectRatio>(
            find.ancestor(
              of: find.byType(Texture),
              matching: find.byType(AspectRatio),
            ),
          )
          .aspectRatio,
      90 / 160,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('collapsePreview')), findsNothing);
    backend.state('waiting');
    await tester.pumpAndSettle();
    expect(find.byType(Texture), findsNothing);
    expect(find.text('等待 iPhone 连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('Stop and error clear texture dimensions; settings API stays platform neutral', () async {
    final backend = FakeReceiver();
    final model = ReceiverModel(backend);
    await model.initialize();
    for (final status in ['stopping', 'stopped', 'error']) {
      backend.controller.add({
        'type': 'video',
        'textureId': 7,
        'videoWidth': 320,
        'videoHeight': 180,
      });
      expect(model.hasVideo, true);
      backend.state(status, 0);
      expect(model.hasVideo, false);
    }
    model.dispose();
    await backend.controller.close();
  });

  testWidgets('Settings cancel and escape preserve saved values and focus', (
    tester,
  ) async {
    await screen(tester);
    final backend = FakeReceiver();
    await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('receiverName')), '未保存');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(backend.savedName, isNull);
    expect(FocusManager.instance.primaryFocus?.debugLabel, '接收操作');
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('receiverName')))
          .controller!
          .text,
      'Flutter AirPlay',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(backend.savedName, isNull);
  });

  testWidgets(
    'Phone capabilities hide executable path and use local playback wording',
    (tester) async {
      await screen(tester, const Size(390, 700));
      final backend = FakeReceiver(
        capabilities: {
          'platform': 'android',
          'isTelevision': false,
          'supportsExecutablePath': false,
        },
      );
      await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
      await tester.pumpAndSettle();
      expect(find.textContaining('声音由本设备'), findsOneWidget);
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      expect(find.text('高级设置'), findsNothing);
      expect(find.textContaining('GStreamer'), findsNothing);
      expect(find.byKey(const Key('receiverPath')), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV D-pad activation, layered Back and focus restoration', (
    tester,
  ) async {
    await screen(tester, const Size(1280, 720));
    final backend = FakeReceiver(
      capabilities: {
        'platform': 'android',
        'isTelevision': true,
        'supportsExecutablePath': false,
      },
    );
    await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, '接收操作');
    expect(
      tester.getSize(find.byKey(const Key('start'))).height,
      greaterThanOrEqualTo(56),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(backend.starts, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('collapsePreview')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('collapsePreview')), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, '接收操作');
    expect(backend.stops, 0);
    await tester.tap(find.byKey(const Key('openLogs')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, '接收操作');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Repeated UI starts stay disabled until ready and error offers recovery',
    (tester) async {
      await screen(tester);
      final backend = FakeReceiver()..startup = Completer<void>();
      await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR, platform: 'macos');
      await tester.tap(find.byKey(const Key('stop')));
      await tester.pump();
      expect(backend.starts, 1);
      expect(backend.stops, 0);
      backend.startup!.complete();
      await tester.pumpAndSettle();
      backend.state('error', 0);
      await tester.pumpAndSettle();
      expect(find.text('重新启动'), findsOneWidget);
      expect(find.text('检查环境'), findsOneWidget);
      expect(find.text('打开设置'), findsOneWidget);
      expect(find.text('查看日志'), findsOneWidget);
    },
  );

  testWidgets('Small window, large text and both themes have no overflow', (
    tester,
  ) async {
    await screen(tester, const Size(480, 480));
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(ReceiverApp(model: ReceiverModel(FakeReceiver())));
    await tester.pumpAndSettle();
    for (final label in ['深色', '浅色']) {
      await tester.tap(find.byKey(const Key('appearance')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byKey(const Key('openSettings'))))
            .brightness,
        label == '深色' ? Brightness.dark : Brightness.light,
      );
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
  });

  test(
    'Capabilities are backward compatible and PID is diagnostic only',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final legacy = ReceiverModel(FakeReceiver(capabilities: null));
      await legacy.initialize();
      expect(legacy.supportsExecutablePath, true);
      final backend = FakeReceiver(
        capabilities: {
          'platform': 'android',
          'isTelevision': true,
          'supportsExecutablePath': false,
        },
      );
      final android = ReceiverModel(backend);
      await android.initialize();
      expect(android.platform, 'android');
      expect(android.isTelevision, true);
      expect(android.supportsExecutablePath, false);
      backend.state('waiting', 0);
      expect(android.canStop, true);
      backend.state('stopped', 99);
      expect(android.canStart, true);
      android.dispose();
      legacy.dispose();
    },
  );
}
