// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mixin_logger/mixin_logger.dart';

import 'app/app_logging.dart';
import 'platform/launch_at_login.dart';
import 'receiver/receiver_model.dart';
import 'receiver/receiver_repository.dart';
import 'app/receiver_app.dart';
import 'ui/widgets/system_fonts.dart';

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await initializeLogging();
    try {
      await const LaunchAtLogin().migrateLegacyRegistration();
    } catch (error, stack) {
      // A failed optional migration must not prevent opening the application.
      e('Cannot upgrade the existing login startup entry', error, stack);
    }
    final systemFonts = await SystemFonts.initialize();
    LicenseRegistry.addLicense(() async* {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final path in manifest.listAssets().where(
        (path) => path.startsWith('assets/licenses/'),
      )) {
        final text = await rootBundle.loadString(path);
        yield LicenseEntryWithLineBreaks([path.split('/').last], text);
      }
    });
    runApp(
      ReceiverApp(
        model: ReceiverModel(NativeReceiverRepository()),
        systemFonts: systemFonts,
      ),
    );
  }, (error, stack) => e('Uncaught application error', error, stack));
}
