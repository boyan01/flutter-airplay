// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'desktop_crop_test.dart' as crop;
import 'desktop_hover_test.dart' as hover;
import 'desktop_startup_test.dart' as startup;
import 'desktop_window_test.dart' as window;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Individual entry points used to have separate bindings and pointer policies.
  setUp(() {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fadePointers;
    binding.shouldPropagateDevicePointerEvents = false;
  });
  // Cold startup must run before any other group initializes the receiver host.
  group('startup', startup.main);
  group('crop', crop.main);
  group('hover', () {
    setUp(() {
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
      binding.shouldPropagateDevicePointerEvents = true;
    });
    hover.main();
  });
  group('window', () {
    setUp(() {
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    });
    window.main(smokeOnly: true);
  });
}
