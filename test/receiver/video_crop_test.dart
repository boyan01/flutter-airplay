// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui';

import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_receiver.dart';

void main() {
  const crop = Rect.fromLTWH(.2, .1, .5, .75);
  late FakeReceiver backend;
  late ReceiverModel model;

  Future<void> initialize({bool native = false}) async {
    backend = FakeReceiver(
      autoStart: false,
      capabilities: {'platform': 'macos', 'nativeVideoSurface': native},
    );
    model = ReceiverModel(backend);
    addTearDown(() async {
      model.dispose();
      await backend.controller.close();
    });
    await model.initialize();
  }

  for (final native in [false, true]) {
    test(
      '${native ? 'native' : 'texture'} crop changes effective dimensions only',
      () async {
        await initialize(native: native);
        frame(backend, 1920, 1080);
        if (native) {
          backend.controller.add({
            'type': 'video',
            'textureId': -1,
            'videoWidth': 1920,
            'videoHeight': 1080,
          });
        }
        var notifications = 0;
        model.addListener(() => notifications++);
        model.setVideoCrop(crop);
        expect(model.hasVideo, isTrue);
        expect(model.videoCrop, crop);
        expect(model.displayVideoWidth, 960);
        expect(model.displayVideoHeight, 810);
        expect(model.videoWidth, 1920);
        expect(model.videoHeight, 1080);
        expect(notifications, 1);
        expect(backend.saves, 0);
        model.setVideoCrop(ReceiverModel.fullVideoCrop);
        expect(model.displayVideoWidth, 1920);
        expect(model.displayVideoHeight, 1080);
      },
    );
  }

  test(
    'effective dimensions round partial pixels without changing the source',
    () async {
      await initialize();
      frame(backend, 101, 77);
      model.setVideoCrop(const Rect.fromLTWH(0, 0, .5, .5));
      expect(model.displayVideoWidth, 51);
      expect(model.displayVideoHeight, 39);
      expect(model.videoWidth, 101);
      expect(model.videoHeight, 77);
    },
  );

  for (final snapshot in [false, true]) {
    test(
      '${snapshot ? 'snapshot' : 'video event'} preserves crop at the same aspect and resets changed aspect',
      () async {
        await initialize();
        frame(backend, 1920, 1080);
        model.setVideoCrop(crop);
        Future<void> resize(int width, int height) async {
          if (snapshot) {
            backend.controller.add({
              'type': 'snapshot',
              'data': {
                ...await backend.rawSnapshot(),
                'textureId': 0,
                'videoWidth': width,
                'videoHeight': height,
              },
            });
          } else {
            frame(backend, width, height);
          }
        }

        await resize(1280, 720);
        expect(model.videoCrop, crop);
        expect(model.displayVideoWidth, 640);
        expect(model.displayVideoHeight, 540);
        expect(model.videoCropRevision, 0);
        await resize(720, 1280);
        expect(model.videoCrop, ReceiverModel.fullVideoCrop);
        expect(model.displayVideoWidth, 720);
        expect(model.displayVideoHeight, 1280);
        expect(model.videoCropRevision, 1);
        await resize(1080, 1920);
        expect(model.videoCropRevision, 1);
      },
    );
  }

  for (final status in ['waiting', 'stopping', 'stopped', 'error']) {
    test('$status clears crop before the next connection', () async {
      await initialize();
      frame(backend, 1920, 1080);
      model.setVideoCrop(crop);
      backend.state(status);
      expect(model.videoCrop, ReceiverModel.fullVideoCrop);
      expect(model.hasVideo, isFalse);
      expect(model.displayVideoWidth, 0);
      expect(model.displayVideoHeight, 0);
      frame(backend, 1920, 1080);
      expect(model.videoCrop, ReceiverModel.fullVideoCrop);
    });
  }

  test(
    'same-frame snapshots preserve crop until the receiver generation changes',
    () async {
      await initialize();
      final snapshot = {
        ...await backend.rawSnapshot(),
        'status': 'streaming',
        'textureId': 0,
        'videoWidth': 1920,
        'videoHeight': 1080,
        'generation': 7,
      };
      backend.controller.add({'type': 'snapshot', 'data': snapshot});
      model.setVideoCrop(crop);
      backend.controller.add({'type': 'snapshot', 'data': Map.of(snapshot)});
      expect(model.videoCrop, crop);
      expect(model.displayVideoWidth, 960);
      expect(model.displayVideoHeight, 810);
      backend.controller.add({
        'type': 'snapshot',
        'data': {...snapshot, 'generation': 8},
      });
      expect(model.videoCrop, ReceiverModel.fullVideoCrop);
      expect(model.hasVideo, isTrue);
      expect(model.videoWidth, 1920);
      expect(model.videoHeight, 1080);
      expect(model.displayVideoWidth, 1920);
      expect(model.displayVideoHeight, 1080);
      model.setVideoCrop(crop);
      backend.controller.add({
        'type': 'snapshot',
        'data': {...snapshot, 'generation': 8},
      });
      expect(model.videoCrop, crop);
    },
  );

  test('missing frame dimensions reset crop', () async {
    await initialize();
    for (final dimensions in [(0, 1080), (1920, 0), (0, 0)]) {
      frame(backend, 1920, 1080);
      model.setVideoCrop(crop);
      frame(backend, dimensions.$1, dimensions.$2);
      expect(model.videoCrop, ReceiverModel.fullVideoCrop);
      expect(model.hasVideo, isFalse);
    }
  });

  test('crop is rejected without a usable video', () async {
    await initialize();
    var notifications = 0;
    model.addListener(() => notifications++);
    model.setVideoCrop(crop);
    expect(model.videoCrop, ReceiverModel.fullVideoCrop);
    expect(notifications, 0);
    backend.controller.add({
      'type': 'video',
      'textureId': -1,
      'videoWidth': 1920,
      'videoHeight': 1080,
    });
    notifications = 0;
    model.setVideoCrop(crop);
    expect(model.videoCrop, ReceiverModel.fullVideoCrop);
    expect(notifications, 0);
  });

  test(
    'invalid selections leave the current crop and listeners unchanged',
    () async {
      await initialize();
      frame(backend, 1920, 1080);
      model.setVideoCrop(crop);
      var notifications = 0;
      model.addListener(() => notifications++);
      final invalid = [
        Rect.zero,
        const Rect.fromLTWH(0, 0, .019, .5),
        const Rect.fromLTWH(0, 0, .5, .019),
        const Rect.fromLTWH(0, 0, -.5, .5),
        const Rect.fromLTWH(0, 0, .5, -.5),
        const Rect.fromLTWH(-.01, 0, .5, .5),
        const Rect.fromLTWH(0, -.01, .5, .5),
        const Rect.fromLTWH(.6, 0, .5, .5),
        const Rect.fromLTWH(0, .6, .5, .5),
        Rect.fromLTWH(double.nan, 0, .5, .5),
        Rect.fromLTWH(0, double.nan, .5, .5),
        Rect.fromLTWH(0, 0, double.nan, .5),
        Rect.fromLTWH(0, 0, .5, double.nan),
        const Rect.fromLTWH(double.infinity, 0, .5, .5),
        const Rect.fromLTWH(0, double.infinity, .5, .5),
        const Rect.fromLTWH(0, 0, double.infinity, .5),
        const Rect.fromLTWH(0, 0, .5, double.infinity),
      ];
      for (final selection in invalid) {
        model.setVideoCrop(selection);
        expect(model.videoCrop, crop, reason: '$selection');
      }
      expect(notifications, 0);
    },
  );

  test(
    'minimum crop is accepted and floating point edge overshoot is clamped',
    () async {
      await initialize();
      frame(backend, 1920, 1080);
      model.setVideoCrop(const Rect.fromLTWH(0, 0, .02, .02));
      expect(model.videoCrop, const Rect.fromLTWH(0, 0, .02, .02));
      model.setVideoCrop(const Rect.fromLTRB(.5, .5, 1.0000001, 1.0000001));
      expect(model.videoCrop, const Rect.fromLTRB(.5, .5, 1, 1));
    },
  );
}
