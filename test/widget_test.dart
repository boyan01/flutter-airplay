import 'dart:async';

import 'package:flutter_airplay/main.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_airplay/receiver/receiver_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeReceiver implements ReceiverRepository {
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
    expect(find.text('Flutter 内嵌画面'), findsOneWidget);
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
    expect(
      tester.widget<TextField>(find.byKey(const Key('receiverName'))).enabled,
      false,
    );
    backend.state('streaming');
    await tester.pumpAndSettle();
    expect(find.text('正在接收'), findsOneWidget);
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
    await tester.enterText(find.byKey(const Key('receiverName')), '   ');
    await tester.tap(find.byKey(const Key('start')));
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
    expect(find.text('等待 iPhone 画面'), findsOneWidget);
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
}
