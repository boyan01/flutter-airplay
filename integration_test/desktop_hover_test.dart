// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_airplay/app/receiver_app.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nativeapi/nativeapi.dart' as native;

import '../test/receiver/fake_receiver.dart';
import '../test_driver/native_hover_pointer.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  // Live tests discard physical/OS pointer events unless explicitly enabled.
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('OS hover reveals inactive-window controls without focusing it', (
    tester,
  ) async {
    // No tester mouse events or focus mocks: two real native windows and OS input.
    final pointer = NativeHoverPointer();
    final cursor = pointer.position;
    final backend = FakeReceiver(
      capabilities: {
        'platform': Platform.operatingSystem,
        'nativeVideoSurface': Platform.isMacOS,
      },
    );
    final model = ReceiverModel(backend);
    late native.Window player;
    await const WindowController().withWindow((value) => player = value);
    final other = native.Window.create();
    expect(other, isNotNull);
    addTearDown(() async {
      pointer.move(cursor.x, cursor.y);
      pointer.dispose();
      other!.hide();
      other.dispose();
      await tester.pumpWidget(const SizedBox());
      await backend.controller.close();
    });
    Future<void> waitForNative(
      String phase,
      bool Function() matches, {
      Duration stableFor = const Duration(milliseconds: 600),
    }) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      DateTime? stableSince;
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        expect(tester.takeException(), isNull, reason: phase);
        if (matches()) {
          stableSince ??= DateTime.now();
          if (DateTime.now().difference(stableSince) >= stableFor) return;
        } else {
          stableSince = null;
        }
      }
      fail(
        '$phase did not settle: player=${player.bounds}, '
        'aspect=${player.aspectRatio}, playerFocused=${player.isFocused}, '
        'other=${other!.bounds}, otherFocused=${other.isFocused}',
      );
    }

    await tester.pumpWidget(ReceiverApp(model: model));
    await tester.pumpAndSettle();
    frame(backend);
    // Native presentation startup and sizing outlive Flutter's frame settling.
    // Do not place/focus the test windows while production is still resizing.
    await waitForNative('initial video presentation', () {
      final content = player.contentSize;
      return (player.aspectRatio - 16 / 9).abs() < .001 &&
          (content.width / content.height - 16 / 9).abs() < .01;
    });
    player.bounds = const native.Rectangle(
      x: 30,
      y: 100,
      width: 500,
      height: 500 * 9 / 16,
    );
    await waitForNative(
      'separate player bounds',
      () => player.bounds.width >= 450 && player.bounds.width <= 550,
    );
    other!.bounds = const native.Rectangle(
      x: 650,
      y: 100,
      width: 200,
      height: 200,
    );
    player.show();
    other.show();
    await waitForNative('second native window mapping', () => other.isVisible);
    other.focus();
    await waitForNative(
      'second native window focus',
      () => other.isFocused && !player.isFocused,
    );
    final otherBounds = other.contentBounds;
    final otherScale = pointer.scaleForWindow(other.nativeObject);
    pointer.move(
      (otherBounds.x + otherBounds.width / 2) * otherScale,
      (otherBounds.y + otherBounds.height / 2) * otherScale,
    );
    await tester.pump(const Duration(seconds: 4));
    expect(
      player.isFocused,
      isFalse,
      reason: 'Window manager must keep the second window focused',
    );
    expect(other.isFocused, isTrue);
    expect(find.byKey(const Key('playerControls')), findsNothing);

    void moveTo(Offset local) {
      final bounds = player.contentBounds;
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final scale = pointer.scaleForWindow(player.nativeObject);
      pointer.move(
        (bounds.x + local.dx * bounds.width / size.width) * scale,
        (bounds.y + local.dy * bounds.height / size.height) * scale,
      );
    }

    final logicalSize = tester.view.physicalSize / tester.view.devicePixelRatio;
    final videoPoint = Offset(logicalSize.width / 2, logicalSize.height / 2);
    moveTo(videoPoint);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('playerControls')), findsOneWidget);
    expect(
      player.isFocused,
      isFalse,
      reason: 'Hover must not activate the player',
    );
    expect(other.isFocused, isTrue);
    moveTo(tester.getCenter(find.byKey(const Key('disconnect'))));
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('playerControls')), findsOneWidget);
    moveTo(const Offset(250, 20));
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('playerControls')), findsOneWidget);
    expect(player.isFocused, isFalse);
    moveTo(videoPoint);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('playerControls')), findsNothing);
    expect(other.isFocused, isTrue);
  }, skip: !const bool.fromEnvironment('AIRPLAY_OS_INPUT_TEST'));
}
