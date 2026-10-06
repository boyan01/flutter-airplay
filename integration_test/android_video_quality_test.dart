// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter_airplay/app/receiver_app.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_airplay/receiver/receiver_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android quality persists across native receiver restarts', (
    tester,
  ) async {
    final repository = NativeReceiverRepository();
    final original = await repository.snapshot();
    final model = ReceiverModel(repository);
    await tester.pumpWidget(ReceiverApp(model: model));

    Future<void> waitFor(String status) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while ((!model.loaded ||
              model.busy ||
              model.settingsPending ||
              model.status != status) &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(model.status, status, reason: model.commandError ?? model.message);
      expect(model.commandError, isNull);
    }

    try {
      if (original.settings.autoStart == false &&
          original.status.name == 'stopped') {
        await waitFor('stopped');
        await model.start(model.name, model.path);
      }
      await waitFor('waiting');
      expect(model.supportsVideoQuality, isTrue);
      expect(model.screenWidth, greaterThan(0));
      expect(model.screenHeight, greaterThan(0));
      for (final quality in [
        ...model.videoQualities.where((v) => v != 'auto'),
        'auto',
      ]) {
        await model.save(model.name, model.path, videoQuality: quality);
        await waitFor('waiting');
        var saved = await repository.snapshot();
        expect(saved.settings.videoQuality.value, quality);
        expect(saved.activeSettings!.videoQuality.value, quality);
        expect(saved.videoWidth, 0, reason: 'A request is not a decoded frame');
        expect(saved.videoHeight, 0);
        await model.stop();
        await waitFor('stopped');
        await model.start(model.name, model.path);
        await waitFor('waiting');
        saved = await repository.snapshot();
        expect(saved.settings.videoQuality.value, quality);
        expect(saved.activeSettings!.videoQuality.value, quality);
        expect(
          saved.textureId,
          -1,
          reason: 'Android uses a native SurfaceView',
        );
      }
    } finally {
      await repository.stop();
      await repository.save(
        original.settings.name,
        '',
        autoStart: original.settings.autoStart,
        videoQuality: original.settings.videoQuality.value,
      );
    }
  }, skip: defaultTargetPlatform != TargetPlatform.android);
}
