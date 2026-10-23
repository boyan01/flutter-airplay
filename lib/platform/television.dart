// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mixin_logger/mixin_logger.dart';

// Read once before the first frame, so the TV layout never starts as the phone one.
Future<bool> isTelevisionDevice() async {
  // Preview the TV interface on a macOS debug build.
  if (kDebugMode &&
      defaultTargetPlatform == TargetPlatform.macOS &&
      const bool.fromEnvironment('AIRPLAY_DEBUG_TV')) {
    return true;
  }
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await const MethodChannel('tech.soit.flutterairplay/window')
            .invokeMethod<bool>('isTelevision') ??
        false;
  } catch (error, stack) {
    e('Cannot read the Android device type', error, stack);
    return false;
  }
}
