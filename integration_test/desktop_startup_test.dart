// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_airplay/l10n/generated/app_localizations_en.dart';
import 'package:flutter_airplay/platform/desktop_presentation.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_airplay/receiver/native/receiver_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/receiver/fake_receiver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'macOS cold startup completes with a usable tray before the watchdog',
    (tester) async {
      final backend = FakeReceiver(
        capabilities: {'platform': Platform.operatingSystem},
      );
      final model = ReceiverModel(backend);
      const window = WindowController();
      late DesktopPresentation desktop;
      desktop = DesktopPresentation(
        window: window,
        model: model,
        onAction: (action, _) async {
          if (action == WindowAction.closeRequested) await desktop.hide();
        },
        onError: (error) => fail('$error'),
      );
      window.listen((action, expanded) async {
        if (action == WindowAction.closeRequested) await desktop.hide();
      });
      FfiReceiverControl? control;
      addTearDown(() async {
        window.listen(null);
        desktop.dispose();
        control?.dispose();
        model.dispose();
        await backend.controller.close();
      });
      await tester.runAsync(() async {
        final host = await const MethodChannel('org.airplayreceiver/platform')
            .invokeMapMethod<String, dynamic>('bootstrap');
        control = FfiReceiverControl(host!['handle'] as int);
        await control!.request('snapshot');
        await model.initialize();
        await desktop
            .update(AppLocalizationsEn())
            .timeout(const Duration(seconds: 5));
        expect(
          desktop.canHide,
          isTrue,
          reason: 'The tray must be usable before startup completes',
        );
        await window.withWindow(
          (value) => expect(
            value.isVisible,
            isTrue,
            reason: 'Manual cold launch must show the main window',
          ),
        );
        await window.execute(WindowCommand.closeWindow);
        await Future<void>.delayed(const Duration(seconds: 11));
        await window.withWindow(
          (value) => expect(
            value.isVisible,
            isFalse,
            reason:
                'Closing to tray must remain hidden after the startup watchdog',
          ),
        );
        // Exercise the live host after closing. A disposed receiver cannot answer.
        await control!.request('snapshot');
      });
    },
    skip: !Platform.isMacOS,
  );
}
