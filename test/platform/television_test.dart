// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_airplay/platform/television.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tech.soit.flutterairplay/window');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final television in [false, true]) {
    test('Android reports the host device type (TV=$television)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'isTelevision' ? television : null,
      );
      expect(await isTelevisionDevice(), television);
    });
  }

  test('A failed Android lookup falls back to the phone layout', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'failed'),
    );
    expect(await isTelevisionDevice(), isFalse);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    test('${platform.name} is never a TV', () async {
      debugDefaultTargetPlatformOverride = platform;
      expect(await isTelevisionDevice(), isFalse);
    });
  }
}
