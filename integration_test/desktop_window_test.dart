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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Native resize may synchronously deliver frames. Follow the production
  // scheduler even between tester pumps, so window writes can detect a frame.
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
          'supportsExecutablePath': Platform.isMacOS,
        },
      );
      await tester.pumpWidget(ReceiverApp(model: ReceiverModel(backend)));
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('closeSettings')));
      await tester.pumpAndSettle();

      late native.Window window;
      await const WindowController().withWindow((value) => window = value);
      addTearDown(backend.controller.close);

      Future<void> waitForFullscreen(bool target) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (window.isFullScreen != target &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(window.isFullScreen, target);
        // AppKit's style changes before its Space transition finishes.
        await tester.pump(const Duration(seconds: 2));
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
  testWidgets('shared desktop geometry, tray and session window policy', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final backend = FakeReceiver(
      autoStart: false,
      capabilities: {'platform': Platform.operatingSystem},
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
    addTearDown(() {
      controller.listen(null);
      presentation.dispose();
      unawaited(controller.releaseNativeWindow());
      model.dispose();
    });
    addTearDown(backend.controller.close);
    final strings = AppLocalizationsEn();
    Future<void> waitForGeometry(
      bool Function(native.Size) matches,
      String reason,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      DateTime? stableSince;
      native.Size? previous;
      late native.Size current;
      while (DateTime.now().isBefore(deadline)) {
        // Native configuration is asynchronous. Do not wait for a Flutter
        // frame here: a tray-hidden window may stop delivering frames.
        await tester
            .runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              await controller.withWindow(
                (value) => current = value.contentSize,
              );
            })
            .timeout(
              deadline.difference(DateTime.now()),
              onTimeout: () => fail(
                '$reason did not settle; last OS size: '
                '${previous?.width} x ${previous?.height}',
              ),
            );
        expect(tester.takeException(), isNull);
        if (matches(current)) {
          if (previous == null ||
              (current.width - previous.width).abs() > 1 ||
              (current.height - previous.height).abs() > 1) {
            stableSince = DateTime.now();
          }
          stableSince ??= DateTime.now();
          if (DateTime.now().difference(stableSince) >=
              const Duration(milliseconds: 300)) {
            return;
          }
        } else {
          stableSince = null;
        }
        previous = current;
      }
      fail('$reason did not settle: ${current.width} x ${current.height}');
    }

    Future<void> update() async {
      await tester.runAsync(() => presentation.update(strings));
      await tester.pumpAndSettle();
      expect(errors, isEmpty);
      if (!nativeWindow.isFullScreen && !nativeWindow.isMaximized) {
        final ratio = model.hasVideo && model.videoHeight > 0
            ? model.videoWidth / model.videoHeight
            : 0.0;
        await waitForGeometry(
          (size) => ratio > 0
              ? (size.width / size.height - ratio).abs() < .01
              : (size.width - 440).abs() <= 2 && (size.height - 560).abs() <= 2,
          ratio > 0 ? 'Video ratio $ratio' : 'Waiting window',
        );
      }
    }

    await update();
    // API support does not guarantee a registered shell tray (e.g. Openbox).
    // Without one, closing to tray must not make the app inaccessible.
    if (Platform.isLinux && !presentation.canHide) {
      expect(nativeWindow.isVisible, isTrue);
    } else {
      expect(presentation.canHide, native.TrayManager.instance.isSupported());
    }
    expect(nativeWindow.contentSize.width, closeTo(440, 2));
    expect(nativeWindow.contentSize.height, closeTo(560, 2));
    expect(nativeWindow.aspectRatio, 0);
    model.textureId = 1;
    model.videoWidth = 1920;
    model.videoHeight = 1080;
    model.desktopOptions['alwaysOnTop'] = true;
    await update();
    expect(nativeWindow.aspectRatio, closeTo(16 / 9, .001));
    expect(
      nativeWindow.contentSize.width / nativeWindow.contentSize.height,
      closeTo(16 / 9, .01),
    );
    expect(await readWindowAlwaysOnTop(nativeWindow), isTrue);
    final landscape = nativeWindow.contentSize;
    for (var i = 0; i < 3; i++) {
      model.videoWidth = 1080;
      model.videoHeight = 1920;
      await update();
      expect(
        nativeWindow.contentSize.width / nativeWindow.contentSize.height,
        closeTo(9 / 16, .01),
      );
      model.videoWidth = 1920;
      model.videoHeight = 1080;
      await update();
      expect(nativeWindow.contentSize.width, closeTo(landscape.width, 2));
      expect(nativeWindow.contentSize.height, closeTo(landscape.height, 2));
    }
    model.videoWidth = 640;
    model.videoHeight = 360;
    await update();
    await presentation.resize(actualSize: true);
    await tester.pumpAndSettle();
    await waitForGeometry(
      (size) =>
          (size.width * tester.view.devicePixelRatio - 640).abs() <= 2 &&
          (size.height * tester.view.devicePixelRatio - 360).abs() <= 2,
      'Original pixel size',
    );
    expect(
      nativeWindow.contentSize.width * tester.view.devicePixelRatio,
      closeTo(640, 2),
    );
    expect(
      nativeWindow.contentSize.height * tester.view.devicePixelRatio,
      closeTo(360, 2),
    );
    await controller.execute(WindowCommand.enterFullscreen);
    await tester.pump(const Duration(seconds: 2));
    expect(nativeWindow.isFullScreen, isTrue);
    await controller.execute(WindowCommand.exitFullscreen);
    await tester.pump(const Duration(seconds: 2));
    expect(await readWindowAlwaysOnTop(nativeWindow), isTrue);
    await controller.execute(WindowCommand.enterFullscreen);
    await tester.pump(const Duration(seconds: 2));
    model.videoWidth = 0;
    model.videoHeight = 0;
    await update();
    await controller.execute(WindowCommand.exitFullscreen);
    await tester.pump(const Duration(seconds: 2));
    expect(nativeWindow.isFullScreen, isFalse);
    expect(nativeWindow.contentSize.width, closeTo(440, 2));
    expect(nativeWindow.contentSize.height, closeTo(560, 2));
    expect(nativeWindow.aspectRatio, 0);
    expect(await readWindowAlwaysOnTop(nativeWindow), isFalse);
    if (presentation.canHide) {
      debugPrint('Checking close-to-tray after fullscreen restoration');
      await controller.execute(WindowCommand.closeWindow);
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
      model.videoWidth = 1920;
      model.videoHeight = 1080;
      await update();
      expect(
        nativeWindow.isVisible,
        isTrue,
      ); // showOnConnect shares the same native window.
      model.videoWidth = 0;
      model.videoHeight = 0;
      model.audioPlaying = true;
      await update();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 3200)),
      );
      expect(nativeWindow.isVisible, isFalse);
      expect(
        model.audioPlaying,
        isTrue,
      ); // Automatic hiding must not disconnect audio.
      await presentation.show();
      await tester.pumpAndSettle();
      expect(nativeWindow.isVisible, isTrue);
      await presentation.hide(disconnect: false);
      await presentation.show();
      model.videoWidth = 1920;
      model.videoHeight = 1080;
      await update();
      model.videoWidth = 0;
      model.videoHeight = 0;
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
}
