import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_airplay/platform/windows_app_updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'android_app_updates_test.dart' show RoutingClient;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'verifies real publisher output and rejects metadata/key tampering',
    () async {
      final generated = await Process.run(
        Platform.isWindows ? 'python' : 'python3',
        [
          '-c',
          r'''
import sys
from scripts.tests.test_sparkle_release import SparkleTests, release, PUBLIC
case = SparkleTests()
case.setUp()
try:
    feed = case.make_feed()
    setup = case.root / 'Flutter-AirPlay-1.2.3-windows-x64-setup.exe'
    setup.write_bytes(b'installer fixture')
    release.add_windows_appcast(feed, setup, '1.2.3', 4, PUBLIC)
    release.add_windows_appcast(feed, setup, '1.2.3', 4, PUBLIC)
    sys.stdout.write(feed.read_text())
finally:
    case.doCleanups()
''',
        ],
      );
      expect(generated.exitCode, 0, reason: generated.stderr.toString());
      final source = generated.stdout as String;
      final data = WindowsAppUpdateService.parseAppcast(source)!;
      final service = WindowsAppUpdateService(
        publicKey: 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=',
      );
      expect(data['versionCode'], 4);
      expect(data['releaseNotes'], contains('改进投屏'));
      await service.verifyManifest(data);
      for (final replacement in <String, Object>{
        'version': '9.9.9',
        'versionCode': 999,
        'size': 1,
        'sha256': '0' * 64,
        'arch': 'arm64',
        'edSignature': base64Encode(List.filled(64, 0)),
      }.entries) {
        await expectLater(
          service.verifyManifest({...data, replacement.key: replacement.value}),
          throwsA(anything),
        );
      }
      final other = WindowsAppUpdateService(
        publicKey: base64Encode(List.filled(32, 0)),
      );
      await expectLater(other.verifyManifest(data), throwsA(anything));
      expect(
        WindowsAppUpdateService.parseAppcast(
          '<rss><channel><item/></channel></rss>',
        ),
        isNull,
      );
      final entry = RegExp(r'<airplay:windows[^>]+/>')
          .firstMatch(source)!
          .group(0)!;
      expect(
        () => WindowsAppUpdateService.parseAppcast(
          source.replaceFirst(entry, '$entry$entry'),
        ),
        throwsFormatException,
      );
    },
  );

  for (final corrupt in [false, true]) {
    test(
      'Windows download waits for explicit install and verifies bytes (corrupt=$corrupt)',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'AirPlay',
          packageName: 'airplay',
          version: '0.1.5',
          buildNumber: '6',
          buildSignature: '',
        );
        final bytes = List.generate(100, (index) => index);
        final key = await Ed25519().newKeyPairFromSeed(
          List.generate(32, (index) => index),
        );
        final public = await key.extractPublicKey();
        final data = <String, dynamic>{
          'version': '0.1.6',
          'versionCode': 7,
          'arch': 'x64',
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        };
        final signature = await Ed25519().sign(
          WindowsAppUpdateService.signaturePayload(data),
          keyPair: key,
        );
        final manifest =
            '''<rss xmlns:a="https://github.com/boyan01/flutter-airplay/updates"><channel><item>
<description>&lt;p&gt;Update&lt;/p&gt;</description>
<a:windows version="0.1.6" build="7" arch="x64" length="100" sha256="${data['sha256']}"
edSignature="${base64Encode(signature.bytes)}" url="https://github.com/boyan01/flutter-airplay/releases/download/v0.1.6/setup.exe"/>
</item></channel></rss>''';
        final directory = await Directory.systemTemp.createTemp(
          'windows-update-test-',
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0, installs = 0;
        final subscription = server.listen((request) async {
          if (request.uri.path == '/feed') {
            request.response.write(manifest);
          } else {
            requests++;
            request.response.add(corrupt ? List.filled(100, 0) : bytes);
          }
          await request.response.close();
        });
        const channel = MethodChannel(
          'tech.soit.flutterairplay/windowsUpdates',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'install');
          final args = call.arguments as Map;
          expect(args['sha256'], data['sha256']);
          expect(args['path'], endsWith('.exe'));
          installs++;
          if (installs == 1) {
            throw PlatformException(
              code: 'start_failed',
              message: 'Cannot start installer',
            );
          }
          return null;
        });
        final service = WindowsAppUpdateService(
          publicKey: base64Encode(public.bytes),
          clientFactory: () =>
              RoutingClient(Uri.parse('http://127.0.0.1:${server.port}')),
          temporaryDirectory: () async => directory,
        );
        final completed = Completer<Map<String, dynamic>>();
        service.listen((state) {
          if (['ready', 'error'].contains(state['status']) &&
              !completed.isCompleted) {
            completed.complete(state);
          }
        });
        try {
          await service.initialize();
          expect((await service.checkForUpdates())['status'], 'available');
          expect(requests, 0);
          await service.installUpdate();
          final state = await completed.future.timeout(
            const Duration(seconds: 10),
          );
          expect(state['status'], corrupt ? 'error' : 'ready');
          expect(installs, 0);
          expect(
            await Directory('${directory.path}/updates').list().length,
            corrupt ? 0 : 1,
          );
          if (!corrupt) {
            expect(
              (await service.installUpdate())['error'],
              'Cannot start installer',
            );
            await service.installUpdate();
            expect(installs, 2);
            expect(requests, 1);
            expect((await service.showUpdate())['status'], 'installing');
            await service.installUpdate();
            expect(installs, 2);
          }
        } finally {
          service.listen(null);
          messenger.setMockMethodCallHandler(channel, null);
          await subscription.cancel();
          await server.close(force: true);
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
