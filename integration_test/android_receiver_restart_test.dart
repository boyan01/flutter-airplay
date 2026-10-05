// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter_airplay/main.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_airplay/receiver/receiver_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android rename and immediate restart remain discoverable', (
    tester,
  ) async {
    final repository = NativeReceiverRepository();
    final model = ReceiverModel(repository);
    await tester.pumpWidget(ReceiverApp(model: model));

    Future<void> waitFor(String status) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((!model.loaded ||
              model.busy ||
              model.settingsPending ||
              model.status != status) &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(model.busy, isFalse);
      expect(model.status, status, reason: model.message);
      expect(model.commandError, isNull);
      final snapshot = await repository.snapshot();
      expect(snapshot['status'], status);
      if (status == 'waiting') {
        expect(snapshot['pid'], greaterThan(0));
        expect(
          snapshot['textureId'],
          -1,
          reason: 'Android uses a native SurfaceView',
        );
      }
    }

    await waitFor('waiting');
    final originalName = model.name;
    final originalAutoStart = model.autoStart;
    try {
      for (var cycle = 0; cycle < 3; cycle++) {
        await model.save('Rename Regression $cycle', '');
        await waitFor('waiting');
        expect(model.name, 'Rename Regression $cycle');
        final applied = await repository.snapshot();
        expect((applied['activeSettings'] as Map)['name'], model.name);
        expect(applied['receivingName'], contains(model.name));

        await model.stop();
        await waitFor('stopped');
        await model.start(model.name, '');
        await waitFor('waiting');
      }
    } finally {
      // Persist the original settings even when startup cancellation leaves the
      // model in "starting" and disables its normal settings command.
      await repository.stop();
      await repository.save(originalName, '', autoStart: originalAutoStart);
    }
  }, skip: defaultTargetPlatform != TargetPlatform.android);
}
