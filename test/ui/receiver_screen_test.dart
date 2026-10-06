import 'package:flutter_airplay/platform/launch_at_login.dart';
import 'package:flutter_airplay/app/receiver_app.dart';
import 'package:flutter_airplay/ui/logs/logs_page.dart';
import 'package:flutter_airplay/ui/settings/settings_page.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../receiver/fake_receiver.dart';
import '../platform/fake_window.dart';

import 'package:flutter_airplay/platform/window_controller.dart';

class _FakeLogin extends LaunchAtLogin {
  @override
  Future<bool> isEnabled() async => false;
  @override
  Future<bool> setEnabled(bool enabled) async => enabled;
}

void main() {
  Future<FakeReceiver> launch(
    WidgetTester tester, {
    Size size = const Size(440, 650),
    String platform = 'macos',
    bool tv = false,
    bool autoStart = true,
    String locale = 'zh',
    FakeReceiver? backend,
    List<String>? windowCalls,
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
    final window = FakeWindow(calls: windowCalls);
    await tester.pumpWidget(
      ReceiverApp(
        launchAtLogin: _FakeLogin(),
        model: ReceiverModel(backend),
        window: WindowController(withWindow: (action) async => action(window)),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(backend.controller.close);
    return backend;
  }

  testWidgets('macOS title stays at the window center', (tester) async {
    await launch(tester, size: const Size(600, 650));
    final title = find.descendant(
      of: find.byKey(const Key('windowDragArea')),
      matching: find.byType(Text),
    );
    expect(tester.getCenter(title).dx, closeTo(300, 0.5));
  });

  for (final platform in ['macos', 'windows', 'linux']) {
    testWidgets(
      '$platform desktop title stays outside navigation and dialog transitions',
      (tester) async {
        await launch(tester, platform: platform, size: const Size(600, 650));
        final bar = find.byKey(
          Key(platform == 'macos' ? 'macWindowBar' : '${platform}WindowBar'),
        );
        final element = tester.element(bar);
        expect(
          find.ancestor(of: bar, matching: find.byType(Navigator)),
          findsNothing,
        );
        final origin = tester.getTopLeft(bar);
        await tester.tap(find.byKey(const Key('openSettings')));
        await tester.pump(const Duration(milliseconds: 80));
        expect(bar, findsOneWidget);
        expect(tester.element(bar), same(element));
        expect(tester.getTopLeft(bar), origin);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('closeSettings')));
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.element(bar), same(element));
        expect(tester.getTopLeft(bar), origin);
        expect(
          find.ancestor(of: bar, matching: find.byType(Navigator)),
          findsNothing,
        );
      },
    );
  }

  for (final width in [200.0, 280.0, 600.0]) {
    testWidgets('player controls align at width $width', (tester) async {
      final backend = await launch(tester, size: Size(width, 650));
      frame(backend);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 200));
      final disconnect = find.byKey(const Key('disconnect'));
      final fullscreen = find.descendant(
        of: find.byKey(const Key('playerControls')),
        matching: find.widgetWithIcon(IconButton, Icons.fullscreen),
      );
      expect(
        tester.getCenter(disconnect).dy,
        closeTo(tester.getCenter(fullscreen).dy, 0.5),
      );
      if (width < 300) {
        expect(
          find.descendant(of: disconnect, matching: find.byType(Text)),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large text and resizing switch the player to icons', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final backend = await launch(
      tester,
      locale: 'en',
      size: const Size(600, 650),
    );
    frame(backend);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 200));
    final disconnect = find.byKey(const Key('disconnect'));
    expect(tester.widget(disconnect), isA<IconButton>());
    await tester.binding.setSurfaceSize(const Size(240, 650));
    await tester.pump();
    expect(tester.widget(disconnect), isA<IconButton>());
    final fullscreen = find.descendant(
      of: find.byKey(const Key('playerControls')),
      matching: find.widgetWithIcon(IconButton, Icons.fullscreen),
    );
    expect(
      tester.getCenter(disconnect).dy,
      closeTo(tester.getCenter(fullscreen).dy, 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  for (final target in ['macos', 'windows', 'linux', 'ios', 'android', 'tv']) {
    testWidgets(
      '$target playback statistics overlay follows controls and persists',
      (tester) async {
        final backend = await launch(
          tester,
          platform: target == 'tv' ? 'android' : target,
          tv: target == 'tv',
          size: const Size(390, 800),
        );
        await tester.tap(find.byKey(const Key('openSettings')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('advancedSettings')));
        await tester.tap(find.byKey(const Key('advancedSettings')));
        await tester.pumpAndSettle();
        final toggle = find.byKey(const Key('showPlaybackStats'));
        await tester.ensureVisible(toggle);
        backend.saveFailure = 'Could not save overlay';
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
        backend.saveFailure = null;
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(backend.savedShowPlaybackStats, isTrue);
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        if (target == 'macos' || target == 'windows' || target == 'linux') {
          await tester.tap(find.byKey(const Key('closeSettings')));
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        frame(backend);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('playerControls')), findsNothing);
        expect(find.byKey(const Key('playbackStatsOverlay')), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('playbackStatsOverlay')), findsOneWidget);
        backend.controller.add({
          'type': 'playbackStats',
          'metrics': {
            'codec': 'HEVC',
            'decoder': 'Fixture decoder',
            'audioCodec': 'AAC',
            'audioSampleRate': 44100,
            'audioChannels': 2,
            'fps': 59.8,
            'submitted': 120,
            'dropped': 3,
            'pending': 2,
            'queued': 1,
          },
        });
        await tester.pump();
        expect(find.text('HEVC · Fixture decoder'), findsOneWidget);
        expect(find.text('AAC · 44.1 kHz · 2 ch'), findsOneWidget);
        expect(find.text('FPS 59.8'), findsOneWidget);
        expect(find.text('Pending 2/-'), findsOneWidget);
        expect(find.text('· Queue 1/-'), findsOneWidget);
        expect(find.text('Underrun -'), findsOneWidget);
        expect(find.text('V/A   Drop 3/-'), findsOneWidget);
        await tester.binding.setSurfaceSize(const Size(280, 320));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (target == 'tv') {
          await tester.pump(const Duration(seconds: 6));
        } else {
          await tester.tap(
            find.byKey(const Key('playbackStatsOverlay')),
            warnIfMissed: false,
          );
          await tester.pump(const Duration(milliseconds: 350));
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('playerControls')), findsNothing);
        expect(find.byKey(const Key('playbackStatsOverlay')), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('playerControls')), findsOneWidget);
        expect(find.byKey(const Key('playbackStatsOverlay')), findsOneWidget);
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('playerControls')), findsNothing);
        expect(find.byKey(const Key('playbackStatsOverlay')), findsNothing);
        backend.state('waiting');
        await tester.pumpAndSettle();
        frame(backend);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(find.text('Waiting…'), findsOneWidget);
        expect(find.text('HEVC · Fixture decoder'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final target in ['macos', 'windows', 'linux', 'ios', 'android', 'tv']) {
    testWidgets('$target advanced pairing saves and recovers from failure', (
      tester,
    ) async {
      final backend = await launch(
        tester,
        platform: target == 'tv' ? 'android' : target,
        tv: target == 'tv',
        size: target == 'tv' ? const Size(960, 540) : const Size(390, 800),
      );
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('advancedSettings')));
      await tester.tap(find.byKey(const Key('advancedSettings')));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('fastPairing'));
      await tester.ensureVisible(toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      backend.saveFailure = 'Could not save pairing';
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(backend.savedFastPairing, isFalse);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      expect(find.text('Could not save pairing'), findsWidgets);
      backend.saveFailure = null;
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(backend.savedFastPairing, isTrue);
      expect(backend.activeSettings['fastPairing'], isTrue);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(backend.savedFastPairing, isFalse);
      expect(backend.activeSettings['fastPairing'], isFalse);
      expect(backend.fastPairingCalls, [true, true, false]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final platform in ['macos', 'windows', 'linux']) {
    for (final size in [const Size(440, 560), const Size(900, 1000)]) {
      testWidgets('$platform settings fill content height at $size', (
        tester,
      ) async {
        await launch(tester, size: size, platform: platform);
        await tester.tap(find.byKey(const Key('openSettings')));
        await tester.pumpAndSettle();
        final panel = tester.getRect(find.byType(SettingsPage));
        expect(panel.top, 36);
        expect(panel.bottom, size.height);
        expect(panel.width, size.width.clamp(0, 480));
        expect(find.byKey(const Key('closeSettings')), findsOneWidget);
        await tester.ensureVisible(find.text('开源许可'));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('closeSettings')));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPage), findsNothing);
        expect(
          find.byKey(
            Key(platform == 'macos' ? 'macWindowBar' : '${platform}WindowBar'),
          ),
          findsOneWidget,
        );
      });
    }
  }

  for (final platform in ['macos', 'ios', 'android', 'linux', 'windows']) {
    for (final time in ['', '2026-10-05T01:02:03Z']) {
      testWidgets('$platform settings show version with build time "$time"', (
        tester,
      ) async {
        await launch(
          tester,
          size: const Size(1000, 1200),
          backend: FakeReceiver(
            capabilities: {'platform': platform},
            buildVersion: '0.1.2 (3)',
            buildTime: time,
          ),
        );
        await tester.tap(find.byKey(const Key('openSettings')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('buildInfo')));
        final tile = tester.widget<ListTile>(
          find.byKey(const Key('buildInfo')),
        );
        expect((tile.title! as Text).data, '版本: 0.1.2 (3)');
        if (time.isEmpty) {
          expect(tile.subtitle, isNull);
        } else {
          final local = DateTime.parse(time).toLocal();
          String pad(int value) => value.toString().padLeft(2, '0');
          final formatted =
              '${local.year}-${pad(local.month)}-${pad(local.day)} '
              '${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
          expect((tile.subtitle! as Text).data, '构建时间: $formatted');
        }
      });
    }
  }

  for (final locale in ['zh', 'en']) {
    testWidgets('$locale Android settings keep consistent content edges', (
      tester,
    ) async {
      final chinese = locale == 'zh';
      await launch(
        tester,
        locale: locale,
        platform: 'android',
        size: const Size(390, 900),
        backend: FakeReceiver(capabilities: {'platform': 'android'}),
      );
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      final left = tester.getTopLeft(find.byKey(const Key('receiverName'))).dx;
      void expectLeft(String text) {
        expect(tester.getTopLeft(find.text(text)).dx, closeTo(left, 0.1));
      }

      expectLeft(chinese ? '打开应用时自动接收' : 'Receive automatically on launch');
      expectLeft(chinese ? '投屏清晰度' : 'Mirroring quality');
      expectLeft(
        chinese ? '收到投屏时自动打开应用' : 'Open the app when AirPlay connects',
      );
      expectLeft(chinese ? '应用权限与通知' : 'App permissions and notifications');
      expect(find.text(chinese ? '完成' : 'Done'), findsNothing);
      await tester.ensureVisible(find.text(chinese ? '接收日志' : 'Receiver logs'));
      expectLeft(chinese ? '接收日志' : 'Receiver logs');
      await tester.ensureVisible(
        find.text(chinese ? '开源许可' : 'Open-source licenses'),
      );
      expectLeft(chinese ? '开源许可' : 'Open-source licenses');

      await tester.ensureVisible(find.byKey(const Key('videoQuality')));
      await tester.tap(find.byKey(const Key('videoQuality')));
      await tester.pumpAndSettle();
      for (final text
          in chinese
              ? ['适配本机', '流畅 · 720p', '标准 · 1080p']
              : ['Fit this device', 'Smooth · 720p', 'Standard · 1080p']) {
        expectLeft(text);
      }
      expect(find.text(chinese ? '完成' : 'Done'), findsNothing);
      await tester.tap(find.byKey(const Key('quality720')));
      await tester.pumpAndSettle();
      expectLeft(chinese ? '流畅 · 720p' : 'Smooth · 720p');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('advancedSettings')));
      await tester.tap(find.byKey(const Key('advancedSettings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('audioOutput')));
      expectLeft(chinese ? '音频输出' : 'Audio output');
      await tester.tap(find.byKey(const Key('audioOutput')));
      await tester.pumpAndSettle();
      for (final text
          in chinese
              ? ['自动（推荐）', '低延迟', '兼容']
              : ['Automatic (recommended)', 'Low latency', 'Compatible']) {
        expectLeft(text);
      }
      expect(find.text(chinese ? '完成' : 'Done'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'TV logs page scrolls with remote and keeps sharing enabled after clearing',
    (tester) async {
      final backend = await launch(
        tester,
        platform: 'android',
        tv: true,
        size: const Size(960, 540),
      );
      final model = tester.widget<ReceiverApp>(find.byType(ReceiverApp)).model;
      for (var id = 0; id < 100; id++) {
        backend.controller.add({
          'type': 'log',
          'entry': {
            'id': id,
            'time': '2026-10-04T12:30:08',
            'text': 'Video log $id',
          },
        });
      }
      Navigator.of(
        tester.element(find.byType(Scaffold).first),
      ).push<void>(MaterialPageRoute(builder: (_) => LogsPage(model: model)));
      await tester.pumpAndSettle();
      expect(find.byType(LogsPage), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      final list = tester.widget<ListView>(find.byKey(const Key('logList')));
      final logFocus = find.byWidgetPredicate(
        (widget) => widget is Focus && widget.debugLabel == 'Log list',
      );
      Focus.of(
        tester.element(
          find.descendant(of: logFocus, matching: find.byType(Scrollbar)),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(list.controller!.offset, 100);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(list.controller!.offset, 0);
      await tester.tap(find.text('清空当前列表'));
      await tester.pumpAndSettle();
      expect(model.logs, isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('shareLogs')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(LogsPage), findsNothing);
      expect(backend.stops, 0);
    },
  );

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
      expect(find.text('等待 iPhone 连接'), findsOneWidget);
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

  testWidgets('Launch automatically receives without an idle preview', (
    tester,
  ) async {
    final backend = await launch(tester);
    expect(backend.starts, 1);
    expect(find.text('等待 iPhone 连接'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
    expect(find.byKey(const Key('appearance')), findsNothing);
    await tester.tap(find.byKey(const Key('receiveSwitch')));
    await tester.pumpAndSettle();
    expect(backend.stops, 1);
    expect(find.text('接收已关闭'), findsOneWidget);
  });

  testWidgets('All home states render and command errors offer recovery', (
    tester,
  ) async {
    final backend = await launch(tester, autoStart: false);
    for (final entry in {
      'stopped': '接收已关闭',
      'checking': '正在启动…',
      'starting': '正在启动…',
      'waiting': '等待 iPhone 连接',
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

  testWidgets('Rename applies automatically while waiting', (tester) async {
    final backend = await launch(tester);
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('receiverName')),
      'Living Room',
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(backend.savedName, 'Living Room');
    expect(backend.startedName, 'Living Room');
    expect(backend.starts, 2);
    expect(backend.stops, 1);
  });

  for (final locale in ['en', 'zh']) {
    testWidgets('$locale generated name saves automatically', (tester) async {
      final backend = await launch(tester, locale: locale);
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('randomReceiverName')));
      final name = tester
          .widget<TextField>(find.byKey(const Key('receiverName')))
          .controller!
          .text;
      expect(name, matches(RegExp(r' \d{4}$')));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(backend.savedName, name);
      expect(backend.stops, 1);
    });
  }

  testWidgets('TV generated name saves without confirmation', (tester) async {
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
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    final name = tester
        .widget<TextField>(find.byKey(const Key('receiverName')))
        .controller!
        .text;
    expect(backend.savedName, name);
    expect(backend.stops, 1);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tvName')), findsOneWidget);
  });

  testWidgets('Android system permission entries preserve reception', (
    tester,
  ) async {
    const window = MethodChannel('tech.soit.flutterairplay/window');
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
      await tester.pumpAndSettle();
      expect(backend.autoStart, false);
      expect(backend.stops, 0);
    },
  );

  testWidgets(
    'Invalid names preserve saved values; returning flushes valid edits',
    (tester) async {
      final backend = await launch(tester, autoStart: false);
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('receiverName')), '   ');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text('请输入设备名'), findsOneWidget);
      expect(backend.savedName, isNull);
      await tester.enterText(find.byKey(const Key('receiverName')), 'Office');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(backend.savedName, 'Office');
      expect(backend.starts, 0);
      expect(find.byKey(const Key('receiverName')), findsNothing);
    },
  );

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
      expect(find.text('等待 iPhone 连接'), findsOneWidget);
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

  testWidgets(
    'Android TV Back toggles playback controls once per system return',
    (tester) async {
      final backend = await launch(
        tester,
        platform: 'android',
        tv: true,
        size: const Size(960, 540),
      );
      frame(backend);
      await tester.pumpAndSettle();
      for (final visible in [true, false, true]) {
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.goBack,
          physicalKey: PhysicalKeyboardKey.escape,
          platform: 'android',
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.goBack,
          physicalKey: PhysicalKeyboardKey.escape,
          platform: 'android',
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('playerControls')),
          visible ? findsOneWidget : findsNothing,
        );
      }
      expect(backend.stops, 0);
    },
  );

  testWidgets('holding TV keyboard Escape does not toggle controls twice', (
    tester,
  ) async {
    final backend = await launch(
      tester,
      platform: 'android',
      tv: true,
      size: const Size(960, 540),
    );
    frame(backend);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playerControls')), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playerControls')), findsNothing);
    expect(backend.stops, 0);
  });

  testWidgets('TV focus ring follows home actions and restores after a route', (
    tester,
  ) async {
    await launch(
      tester,
      platform: 'android',
      tv: true,
      size: const Size(960, 540),
    );
    final ring = find.byKey(const Key('tvFocusRing'));
    expect(
      tester.getRect(ring),
      tester.getRect(find.byKey(const Key('openSettings'))).inflate(3),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(ring),
      tester.getRect(find.byKey(const Key('openLogs'))).inflate(3),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(ring),
      tester.getRect(find.byKey(const Key('shareLogs'))).inflate(3),
    );
    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
      platform: 'android',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester.getRect(ring),
      tester.getRect(find.byKey(const Key('openSettings'))).inflate(3),
    );
    expect(tester.takeException(), isNull);
  });

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

  for (final platform in ['android', 'macos', 'windows', 'linux', 'ios']) {
    test(
      '$platform quality applies after streaming and persists on reload',
      () async {
        final backend = FakeReceiver(
          capabilities: {'platform': platform},
          enableVideoQuality: true,
          videoQualities: const ['auto', '720', '1080', '1440', '2160'],
        );
        final model = ReceiverModel(backend);
        await model.initialize();
        backend.state('streaming');
        await model.save(model.name, model.path, videoQuality: '1440');
        expect(model.settingsPending, isTrue);
        expect(backend.stops, 0);
        expect(backend.activeSettings['videoQuality'], 'auto');
        backend.state('waiting');
        await Future<void>.delayed(Duration.zero);
        expect(backend.stops, 1);
        expect(backend.activeSettings['videoQuality'], '1440');
        expect(model.settingsPending, isFalse);
        final restored = ReceiverModel(backend);
        await restored.initialize();
        expect(restored.videoQuality, '1440');
        model.dispose();
        restored.dispose();
        await backend.controller.close();
      },
    );

    testWidgets('$platform quality saves on selection and persists on return', (
      tester,
    ) async {
      final backend = await launch(
        tester,
        platform: platform,
        size: const Size(1000, 900),
        backend: FakeReceiver(
          capabilities: {'platform': platform},
          enableVideoQuality: platform != 'android',
          videoQualities: const ['auto', '720', '1080', '1440', '2160'],
        ),
      );
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('videoQuality')));
      await tester.tap(find.byKey(const Key('videoQuality')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('quality2160')));
      await tester.pumpAndSettle();
      expect(backend.savedVideoQuality, '2160');
      expect(backend.stops, 1);
      expect(backend.starts, 2);
      expect(find.text('完成'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('超高清 · 4K'), findsOneWidget);
    });
  }

  testWidgets('Unsupported quality stays disabled', (tester) async {
    await launch(tester, platform: 'android');
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('videoQuality')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<RadioListTile<String>>(find.byKey(const Key('quality1440')))
          .enabled,
      isFalse,
    );
  });

  for (final tv in [false, true]) {
    testWidgets('Audio output saves immediately on ${tv ? "TV" : "phone"}', (
      tester,
    ) async {
      final backend = await launch(
        tester,
        platform: 'android',
        tv: tv,
        backend: FakeReceiver(
          capabilities: {'platform': 'android', 'isTelevision': tv},
        ),
        size: tv ? const Size(960, 540) : const Size(390, 800),
      );
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('advancedSettings')));
      await tester.tap(find.byKey(const Key('advancedSettings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('audioOutput')));
      await tester.tap(find.byKey(const Key('audioOutput')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audioOutputaudiotrack')));
      await tester.pumpAndSettle();
      expect(backend.savedAudioOutput, 'audiotrack');
      expect(backend.stops, 1);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('兼容'), findsOneWidget);
      expect(find.text('完成'), findsNothing);
    });
  }

  testWidgets('Home shows the new advertised name after an idle update', (
    tester,
  ) async {
    final backend = await launch(tester, platform: 'android');
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('receiverName')), 'Office');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('homeDeviceName'))).data,
      'Office',
    );
    expect(find.text('选择「Office」'), findsOneWidget);
    expect(backend.savedName, 'Office');
    expect(backend.stops, 1);
  });

  for (final platform in ['macos', 'ios', 'android', 'windows', 'linux']) {
    test('$platform saved receiver settings update only while idle', () async {
      final backend = FakeReceiver(capabilities: {'platform': platform});
      final model = ReceiverModel(backend);
      await model.initialize();
      backend.connectBeforeApply = true;
      await model.save('Office', '');
      await Future<void>.delayed(Duration.zero);
      expect(backend.stops, 0);
      expect(model.settingsPending, isTrue);
      expect(model.receivingName, 'Flutter AirPlay');
      backend.connectBeforeApply = false;
      backend.state('waiting');
      await Future<void>.delayed(Duration.zero);
      expect(backend.stops, 1);
      expect(model.settingsPending, isFalse);
      expect(model.receivingName, 'Office');
      await model.stop();
      await model.save('Bedroom', '');
      await Future<void>.delayed(Duration.zero);
      expect(backend.starts, 2);
      expect(model.status, 'stopped');
      model.dispose();
      await backend.controller.close();
    });
  }

  for (final tv in [false, true]) {
    testWidgets('Name actions are below the field and reset saves (TV=$tv)', (
      tester,
    ) async {
      final backend = await launch(
        tester,
        platform: 'android',
        tv: tv,
        size: tv ? const Size(960, 540) : const Size(390, 700),
      );
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      if (tv) {
        await tester.tap(find.byKey(const Key('tvName')));
        await tester.pumpAndSettle();
      }
      final field = find.byKey(const Key('receiverName'));
      final random = find.byKey(const Key('randomReceiverName'));
      final reset = find.byKey(const Key('resetReceiverName'));
      expect(
        tester.getTopLeft(random).dy,
        greaterThan(tester.getBottomLeft(field).dy),
      );
      expect(
        tester.getTopLeft(reset).dy,
        greaterThan(tester.getBottomLeft(field).dy),
      );
      expect(find.text('System Device'), findsNothing);
      if (tv) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(reset);
      }
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(backend.savedName, 'System Device');
      expect(backend.startedName, 'System Device');
      expect(backend.stops, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Failed automatic save keeps the old selection and can be retried',
    (tester) async {
      final backend = await launch(tester, platform: 'android');
      await tester.tap(find.byKey(const Key('openSettings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('videoQuality')));
      await tester.pumpAndSettle();
      backend.saveFailure = 'Could not save settings';
      await tester.tap(find.byKey(const Key('quality720')));
      await tester.pumpAndSettle();
      expect(find.text('Could not save settings'), findsOneWidget);
      expect(backend.savedVideoQuality, isNull);
      backend.saveFailure = null;
      await tester.tap(find.byKey(const Key('quality720')));
      await tester.pumpAndSettle();
      expect(backend.savedVideoQuality, '720');
      expect(find.text('Could not save settings'), findsNothing);
      expect(backend.stops, 1);
    },
  );

  testWidgets(
    'TV D-pad focus does not select; selection saves without a footer',
    (tester) async {
      final backend = await launch(
        tester,
        platform: 'android',
        tv: true,
        size: const Size(960, 540),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('videoQuality')));
      await tester.tap(find.byKey(const Key('videoQuality')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(backend.savedVideoQuality, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(backend.savedVideoQuality, '720');
      expect(backend.stops, 1);
      expect(find.text('完成'), findsNothing);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.binding.setSurfaceSize(const Size(390, 560));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final tv in [false, true]) {
    for (final page in [
      'settings',
      'logs',
      'quality',
      'audio',
      if (tv) 'name',
    ]) {
      testWidgets('Android ${tv ? 'TV' : 'phone'} back closes only $page', (
        tester,
      ) async {
        final backend = await launch(
          tester,
          platform: 'android',
          tv: tv,
          size: tv ? const Size(960, 540) : const Size(390, 700),
        );
        final systemPops = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'SystemNavigator.pop') systemPops.add(call);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.tap(find.byKey(const Key('openSettings')));
        await tester.pumpAndSettle();
        if (page != 'settings') {
          if (page == 'audio') {
            await tester.ensureVisible(
              find.byKey(const Key('advancedSettings')),
            );
            await tester.tap(find.byKey(const Key('advancedSettings')));
            await tester.pumpAndSettle();
          }
          final entry = switch (page) {
            'logs' => find.text('接收日志'),
            'audio' => find.byKey(const Key('audioOutput')),
            'name' => find.byKey(const Key('tvName')),
            _ => find.byKey(const Key('videoQuality')),
          };
          await tester.ensureVisible(entry);
          await tester.tap(entry);
          await tester.pumpAndSettle();
        }
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        final route = ModalRoute.of(tester.element(find.byType(AppBar).last))!;
        expect(route.isCurrent, isTrue);

        // Android must receive the complete key sequence before navigating.
        expect(
          await tester.sendKeyDownEvent(
            LogicalKeyboardKey.goBack,
            physicalKey: PhysicalKeyboardKey.escape,
            platform: 'android',
          ),
          isFalse,
        );
        await tester.pumpAndSettle();
        expect(route.isCurrent, isTrue);
        expect(
          await tester.sendKeyUpEvent(
            LogicalKeyboardKey.goBack,
            physicalKey: PhysicalKeyboardKey.escape,
            platform: 'android',
          ),
          isFalse,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(route.isCurrent, isFalse);
        expect(navigator.canPop(), {'quality', 'audio', 'name'}.contains(page));
        expect(systemPops, isEmpty);
        expect(backend.stops, 0);
      });
    }
  }

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
          find.text(locale == 'en' ? 'Waiting for iPhone' : '等待 iPhone 连接'),
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
    expect(find.text('Waiting for iPhone'), findsOneWidget);
    expect(backend.starts, 1);
  });

  testWidgets('Settings log entry opens the dedicated logs page', (
    tester,
  ) async {
    await launch(tester, platform: 'android');
    await tester.tap(find.byKey(const Key('openSettings')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('接收日志'));
    await tester.tap(find.text('接收日志'));
    await tester.pumpAndSettle();
    expect(find.byType(LogsPage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('分享日志文件'), findsOneWidget);
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

  testWidgets('TV name saves automatically and survives returning', (
    tester,
  ) async {
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
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(backend.savedName, 'Living Room');
    expect(backend.stops, 1);
    expect(find.byKey(const Key('tvName')), findsOneWidget);
  });

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
  for (final tv in [false, true]) {
    testWidgets('Android native video preserves controls (TV=$tv)', (
      tester,
    ) async {
      final backend = await launch(tester, platform: 'android', tv: tv);
      backend.state('streaming');
      backend.controller.add({
        'type': 'video',
        'textureId': -1,
        'videoWidth': 1920,
        'videoHeight': 1080,
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nativeVideoSurface')), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.backgroundColor, Colors.transparent);
      await tester.tap(find.byKey(const Key('playerPage')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('disconnect')), findsOneWidget);
      await tester.tap(find.byKey(const Key('disconnect')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nativeVideoSurface')), findsNothing);
      expect(backend.stops, 1);
    });
  }

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
      final calls = <String>[];
      const channel = MethodChannel('tech.soit.flutterairplay/window');
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
      await launch(tester, windowCalls: calls);
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
      expect(calls, [
        'closeWindow',
        'minimize',
        'fullscreen:true',
        'fullscreen:false',
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
      expect(find.text('请保持应用在前台'), findsOneWidget);
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
    testWidgets(
      '$platform window shortcuts work from caption focus without repeats',
      (tester) async {
        final calls = <String>[];
        await launch(tester, platform: platform, windowCalls: calls);
        await tester.tap(find.byKey(const Key('windowMinimize')));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.f11);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f11);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.f11);
        expect(calls, ['minimize', 'fullscreen:true']);
      },
    );
  }

  for (final platform in ['windows', 'linux']) {
    testWidgets('$platform player uses supported desktop controls', (
      tester,
    ) async {
      const channel = MethodChannel('tech.soit.flutterairplay/window');
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
      final backend = await launch(
        tester,
        platform: platform,
        windowCalls: calls,
      );
      expect(find.textContaining('DRM'), findsNothing);
      frame(backend);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playerPage')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const Key('macWindowBar')), findsNothing);
      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.byKey(Key('${platform}WindowBar')), findsOneWidget);
      await tester.tap(find.byIcon(Icons.fullscreen));
      expect(calls, contains('fullscreen:true'));
      expect(tester.takeException(), isNull);
    });
  }
  for (final platform in ['windows', 'linux']) {
    testWidgets(
      '$platform caption uses native window operations and preserves desktop preferences',
      (tester) async {
        const channel = MethodChannel('tech.soit.flutterairplay/window');
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
        final backend = await launch(
          tester,
          platform: platform,
          windowCalls: calls,
        );
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
          'minimize',
          'maximize',
          'closeWindow',
          'unmaximize',
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
          isNotNull,
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
        const channel = MethodChannel('tech.soit.flutterairplay/window');
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
        final backend = await launch(
          tester,
          platform: platform,
          windowCalls: calls,
        );
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
        expect(calls, contains('fullscreen:true'));
      },
    );
    testWidgets(
      '$platform tray actions reuse reception and update window state',
      (tester) async {
        final calls = <String>[];
        const channel = MethodChannel('tech.soit.flutterairplay/window');
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
        final backend = await launch(
          tester,
          platform: platform,
          windowCalls: calls,
        );
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
        await nativeCall('enterFullscreen');
        await nativeCall('enterFullscreen');
        await nativeCall('toggleFullscreen');
        expect(calls, [
          'fullscreen:true',
          'fullscreen:true',
          'fullscreen:false',
        ]);
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
