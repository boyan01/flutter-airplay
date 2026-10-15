// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';

import '../receiver/fake_receiver.dart';

void main() {
  for (final platform in ['macos', 'windows', 'android']) {
    for (final nativeTv in [false, true]) {
      test('$platform preserves native capabilities (TV=$nativeTv)', () async {
        final backend = FakeReceiver(
          autoStart: false,
          capabilities: {'platform': platform, 'isTelevision': nativeTv},
        );
        final model = ReceiverModel(backend);
        addTearDown(() async {
          model.dispose();
          await backend.controller.close();
        });
        await model.initialize();
        final expected =
            nativeTv ||
            (kDebugMode &&
                platform == 'macos' &&
                const bool.fromEnvironment('AIRPLAY_DEBUG_TV'));
        expect(model.isTelevision, expected);
        expect(model.platform, platform);
        expect(model.supportsWindowPreferences, platform != 'android');
        backend.state('waiting');
        expect(model.isTelevision, expected);
        expect(model.platform, platform);
      });
    }
  }
}
