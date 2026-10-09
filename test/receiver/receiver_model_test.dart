// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixin_logger/mixin_logger.dart' as logging;
import 'package:flutter_airplay/receiver/receiver_model.dart';

import 'fake_receiver.dart';

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
      final snapshot = await backend.rawSnapshot();
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

  test('Audio diagnostics reach the file logger while playback state stays unchanged', () async {
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
    final snapshot = await backend.rawSnapshot();
    snapshot['status'] = 'streaming';
    snapshot['message'] = 'Playing';
    snapshot['logs'] = [
      {
        'id': 1,
        'time': '2026-10-04T12:30:00Z',
        'text': '[Native level=6] Audio receive totals: packets=100 pcm_packets=100',
      },
      {
        'id': 2,
        'time': '2026-10-04T12:30:05Z',
        'text': '[Native level=6] Android audio output: callbacks_total=0 nonzero_frames_total=0',
      },
    ];
    backend.controller.add({'type': 'snapshot', 'data': snapshot});
    written.clear();
    (snapshot['logs'] as List).add({
      'id': 3,
      'time': '2026-10-04T12:30:10Z',
      'text': 'Android media audio: volume=0/15, muted=true',
    });
    backend.controller.add({'type': 'snapshot', 'data': snapshot});
    expect(written, hasLength(1));
    expect(written.single, contains('volume=0/15, muted=true'));
    expect(
      model.logs.map((entry) => entry.text),
      contains(contains('callbacks_total=0')),
    );
  });

  test('Rename persists during a session without waiting for stop', () async {
    final backend = FakeReceiver()..shutdown = Completer<void>();
    final model = ReceiverModel(backend);
    await model.initialize();
    backend.state('streaming');
    await model.save('New Name', '');
    expect(backend.savedName, 'New Name');
    expect(backend.stops, 0);
    expect(model.status, 'streaming');
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
  test(
    'In-flight starts are ignored and settings do not restart reception',
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
      backend.state('streaming');
      await model.save('Room', '');
      expect(backend.stops, 0);
      expect(backend.savedName, 'Room');
      expect(backend.startedName, 'Office');
      model.dispose();
      await backend.controller.close();
    },
  );
  test(
    'Quality persists across reloads without restarting the receiver',
    () async {
      final backend = FakeReceiver(capabilities: {'platform': 'android'});
      final model = ReceiverModel(backend);
      await model.initialize();
      backend.state('streaming');
      await model.save(model.name, model.path, videoQuality: 'auto');
      expect(backend.stops, 0);
      await model.save(model.name, model.path, videoQuality: '720');
      expect(model.videoQuality, '720');
      expect(backend.stops, 0);
      final restored = ReceiverModel(backend);
      await restored.initialize();
      expect(restored.videoQuality, '720');
      model.dispose();
      restored.dispose();
      await backend.controller.close();
    },
  );
  for (final platform in ['macos', 'ios', 'android', 'windows', 'linux']) {
    test(
      '$platform defers playback buffer until the connection ends',
      () async {
        final backend = FakeReceiver(capabilities: {'platform': platform});
        final model = ReceiverModel(backend);
        await model.initialize();
        expect(model.defaultPlaybackBufferMs, platform == 'macos' ? 120 : 80);
        backend.state('streaming');
        await model.save(model.name, model.path, playbackBufferMs: 60);
        expect(model.settingsPending, isTrue);
        expect(backend.stops, 0);
        expect(backend.activeSettings['playbackBufferMs'], 0);
        backend.state('waiting');
        await Future<void>.delayed(Duration.zero);
        expect(backend.stops, 1);
        expect(backend.activeSettings['playbackBufferMs'], 60);
        expect(model.settingsPending, isFalse);
        model.dispose();
        await backend.controller.close();
      },
    );
  }
  test('Audio selection persists without restarting active receiver', () async {
    final backend = FakeReceiver(capabilities: {'platform': 'android'});
    final model = ReceiverModel(backend);
    await model.initialize();
    expect(model.active, isTrue);
    backend.state('streaming');
    final starts = backend.starts;
    await model.save(model.name, model.path, audioOutput: 'audiotrack');
    expect(backend.savedAudioOutput, 'audiotrack');
    expect(model.audioOutput, 'audiotrack');
    expect(backend.stops, 0);
    expect(backend.starts, starts);
    final restored = ReceiverModel(backend);
    await restored.initialize();
    expect(restored.audioOutput, 'audiotrack');
    model.dispose();
    restored.dispose();
    await backend.controller.close();
  });
  test('Rapid saves are serialized and keep the last edit', () async {
    final backend = FakeReceiver()..saving = Completer<void>();
    final model = ReceiverModel(backend);
    await model.initialize();
    final first = model.save('First', '');
    final second = model.save('Second', '');
    await Future<void>.delayed(Duration.zero);
    expect(backend.saves, 1);
    backend.saving!.complete();
    await Future.wait([first, second]);
    expect(backend.saves, 2);
    expect(backend.savedName, 'Second');
    expect(model.name, 'Second');
    await Future<void>.delayed(Duration.zero);
    expect(backend.stops, 1);
    model.dispose();
    await backend.controller.close();
  });
  test('An apply failure preserves saved settings for recovery', () async {
    final backend = FakeReceiver();
    final model = ReceiverModel(backend);
    await model.initialize();
    backend.failure = 'Port is unavailable';
    await model.save('Office', '');
    await Future<void>.delayed(Duration.zero);
    expect(model.commandError, 'Port is unavailable');
    expect(model.name, 'Office');
    expect(backend.savedName, 'Office');
    expect(model.status, 'error');
    backend.failure = null;
    await model.start(model.name, model.path);
    expect(model.receivingName, 'Office');
    expect(model.commandError, isNull);
    model.dispose();
    await backend.controller.close();
  });
  test('Reverting session edits cancels the pending receiver update', () async {
    final backend = FakeReceiver(capabilities: {'platform': 'android'});
    final model = ReceiverModel(backend);
    await model.initialize();
    backend.state('streaming');
    await model.save('Office', '', videoQuality: '720');
    expect(model.settingsPending, isTrue);
    await model.save('Flutter AirPlay', '', videoQuality: 'auto');
    expect(model.settingsPending, isFalse);
    backend.state('waiting');
    await Future<void>.delayed(Duration.zero);
    expect(backend.stops, 0);
    model.dispose();
    await backend.controller.close();
  });
  test(
    'Queued edits survive asynchronous discovery during an idle update',
    () async {
      final backend = FakeReceiver();
      final model = ReceiverModel(backend);
      await model.initialize();
      backend.completesBeforeReady = true;
      backend.startup = Completer<void>();
      await model.save('First', '');
      await Future<void>.delayed(Duration.zero);
      expect(model.status, 'starting');
      expect(model.editable, isFalse);
      final second = model.save('Second', '');
      backend.startup!.complete();
      await second;
      await Future<void>.delayed(Duration.zero);
      expect(backend.savedName, 'Second');
      expect(model.receivingName, 'Second');
      expect(model.settingsPending, isFalse);
      model.dispose();
      await backend.controller.close();
    },
  );
  test('Receiver settings apply together after the connection ends', () async {
    final backend = FakeReceiver(capabilities: {'platform': 'android'});
    final model = ReceiverModel(backend);
    await model.initialize();
    backend.state('streaming');
    await model.save('Office', '', videoQuality: '720');
    await model.save('Office', '', audioOutput: 'audiotrack');
    expect(backend.stops, 0);
    expect(model.receivingName, 'Flutter AirPlay');
    backend.state('waiting');
    await Future<void>.delayed(Duration.zero);
    expect(backend.stops, 1);
    expect(backend.startedName, 'Office');
    expect(backend.activeSettings['videoQuality'], '720');
    expect(backend.activeSettings['audioOutput'], 'audiotrack');
    model.dispose();
    await backend.controller.close();
  });
  test(
    'Media flags survive snapshots, fresh frames and clear on session end',
    () async {
      final backend = FakeReceiver(autoStart: false);
      final model = ReceiverModel(backend);
      await model.initialize();
      final snapshot = await backend.rawSnapshot();
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
}
