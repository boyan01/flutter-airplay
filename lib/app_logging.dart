// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mixin_logger/mixin_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Directory? loggingDirectory;

Future<void> initializeLogging() async {
  final directory = Platform.isAndroid
      ? await getExternalStorageDirectory() ??
            await getApplicationSupportDirectory()
      : await getApplicationSupportDirectory();
  final path = p.join(directory.path, 'logs');
  loggingDirectory = Directory(path);
  initLogger(path, maxFileCount: 10, maxFileLength: 5 * 1024 * 1024);
  i(
    'Flutter AirPlay started: platform=${Platform.operatingSystem}, '
    'mode=${kReleaseMode ? 'release' : 'debug'}, logs=$path',
  );
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) i('[Flutter] $message');
  };
  FlutterError.onError = (details) {
    e('Flutter framework error', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    e('Uncaught platform error', error, stack);
    return true;
  };
}
