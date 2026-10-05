// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter_airplay/receiver/receiver_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const control = MethodChannel('org.airplayreceiver/control');

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Flutter AirPlay',
      packageName: 'tech.soit.flutterairplay',
      version: '2.3.4',
      buildNumber: '56',
      buildSignature: '',
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(control, null);
  });

  for (final platform in ['macos', 'ios', 'android', 'linux', 'windows']) {
    test(
      '$platform snapshot uses the packaged version and native build time',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(control, (call) async {
              expect(call.method, 'snapshot');
              return {
                'status': 'waiting',
                'buildTime': '2026-10-05T01:02:03Z',
                'capabilities': {'platform': platform},
              };
            });
        final data = await NativeReceiverRepository().snapshot();
        expect(data['buildVersion'], '2.3.4 (56)');
        expect(data['buildTime'], '2026-10-05T01:02:03Z');
        expect(data['status'], 'waiting');
        expect((data['capabilities'] as Map)['platform'], platform);
      },
    );
  }
}
