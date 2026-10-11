// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_airplay/app/receiver_app.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_airplay/ui/playback/video_crop_editor.dart';
import 'package:flutter_airplay/ui/widgets/desktop_window_bar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nativeapi/nativeapi.dart' as native;

import '../test/receiver/fake_receiver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'desktop crop preview preserves the window and commits only on Apply',
    (tester) async {
      final backend = FakeReceiver(
        capabilities: {
          'platform': Platform.operatingSystem,
          'nativeVideoSurface': Platform.isMacOS,
        },
      );
      final model = ReceiverModel(backend);
      const window = WindowController();
      late native.Window host;
      await window.withWindow((value) => host = value);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await backend.controller.close();
      });
      await tester.pumpWidget(ReceiverApp(model: model));
      await tester.pumpAndSettle();
      frame(backend, 1200, 900);

      Future<void> waitForRatio(double ratio) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          if ((host.contentSize.width / host.contentSize.height - ratio).abs() <
              .01) {
            return;
          }
        }
        fail('Window did not reach aspect $ratio: ${host.contentSize}');
      }

      await waitForRatio(4 / 3);
      await tester.tapAt(tester.getCenter(find.byKey(const Key('playerPage'))));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cropVideo')));
      await tester.pumpAndSettle();
      expect(find.byType(VideoCropEditor), findsOneWidget);
      expect(find.byType(DesktopWindowBar), findsNothing);
      final bounds = host.bounds;
      final area = tester.getRect(find.byKey(const Key('cropEditingArea')));
      final selection = tester.getRect(find.byKey(const Key('cropSelection')));
      final surface = Platform.isMacOS
          ? tester.getRect(find.byKey(const Key('nativeVideoSurface')))
          : null;
      if (surface != null) {
        expect(selection.left, closeTo(surface.left, .01));
        expect(selection.right, closeTo(surface.right, .01));
      }
      final corner = tester.getRect(find.byKey(const Key('cropCorner3')));
      expect(corner.bottom, lessThanOrEqualTo(area.bottom));
      await tester.tap(find.byKey(const Key('cropPreview')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cropSelection')), findsNothing);
      expect(model.videoCrop, ReceiverModel.fullVideoCrop);
      expect(host.bounds, bounds);
      expect(tester.getRect(find.byKey(const Key('cropEditingArea'))), area);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const Key('cropSelection'))), selection);
      await tester.tap(find.byKey(const Key('cropPreview')));
      await tester.pumpAndSettle();
      final apply = find.descendant(
        of: find.byType(VideoCropEditor),
        matching: find.byType(FilledButton),
      );
      await tester.tap(apply);
      await tester.pumpAndSettle();
      await waitForRatio(16 / 9);
      expect(find.byType(VideoCropEditor), findsNothing);
      expect(model.videoCrop, const Rect.fromLTWH(0, .125, 1, .75));
      expect(tester.takeException(), isNull);
    },
  );
}
