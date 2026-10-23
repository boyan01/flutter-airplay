// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_airplay/app/receiver_app.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../platform/fake_window.dart';
import '../receiver/fake_receiver.dart';

class _LoadingReceiver extends FakeReceiver {
  _LoadingReceiver() : super(capabilities: {'platform': 'android'}) {
    startup = Completer<void>();
  }

  final snapshotReady = Completer<void>();

  @override
  Future<Map<String, dynamic>> rawSnapshot() async {
    await snapshotReady.future;
    return super.rawSnapshot();
  }
}

void main() {
  for (final locale in ['zh', 'en']) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'TV $locale startup keeps home controls in place at text scale $scale',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(960, 540));
          tester.platformDispatcher.localesTestValue = [Locale(locale)];
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          final backend = _LoadingReceiver()
            ..savedVideoQuality = '720'
            ..savedPlaybackBufferMs = 40;
          final model = ReceiverModel(backend, isTelevision: true);
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            await backend.controller.close();
            await tester.binding.setSurfaceSize(null);
            tester.platformDispatcher.clearLocalesTestValue();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
          });

          await tester.pumpWidget(
            ReceiverApp(
              model: model,
              window: WindowController(
                withWindow: (action) async => action(FakeWindow()),
              ),
            ),
          );
          await tester.pump();
          Map<String, Rect> positions() => {
            for (final key in [
              'homeDeviceName',
              'homeInstructions',
              'homePicture',
              'homeLatency',
              'openSettings',
              'openLogs',
            ])
              key: tester.getRect(find.byKey(Key(key))),
          };

          final loading = positions();
          final quality = find.byKey(const Key('homeQuality'));
          // Reserve the quality row without exposing unloaded settings.
          expect(quality, findsOneWidget);
          for (final key in ['homeQuality', 'homeLatency']) {
            expect(tester.widget<ListTile>(find.byKey(Key(key))).onTap, isNull);
          }

          backend.snapshotReady.complete();
          await tester.pump();
          await tester.pump();
          expect(model.status, 'starting');
          final starting = positions();
          expect(starting, loading);
          final statusPosition = tester.getTopLeft(
            find.byKey(const Key('statusLabel')),
          );

          // Native readiness can arrive before the start command returns.
          backend.state('waiting');
          await tester.pump();
          expect(model.busy, isTrue);
          expect(positions(), starting);
          expect(
            tester.getTopLeft(find.byKey(const Key('statusLabel'))),
            statusPosition,
          );
          backend.startup!.complete();
          await tester.pump();
          await tester.pump();
          expect(model.busy, isFalse);
          expect(model.status, 'waiting');
          expect(positions(), starting);
          expect(
            tester.getTopLeft(find.byKey(const Key('statusLabel'))),
            statusPosition,
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }
}
