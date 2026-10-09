import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_airplay/platform/android_app_updates.dart';
import 'package:flutter_test/flutter_test.dart';

String feed({
  String? android,
  String notes = '&lt;p&gt;中文 &amp;amp; English&lt;/p&gt;',
}) =>
    '''
<rss version="2.0" xmlns:a="${AndroidAppUpdateService.androidNamespace}">
<channel><item><description>$notes</description>
<enclosure url="https://example.com/macos.dmg"/>
${android ?? ''}
</item></channel></rss>''';

String entry({
  String code = '4006',
  String hash = '',
  String? url,
  int length = 100,
}) =>
    '''
<a:android version="0.1.6" versionCode="$code" length="$length"
sha256="${hash.isEmpty ? 'a' * 64 : hash}"
url="${url ?? 'https://github.com/boyan01/flutter-airplay/releases/download/v0.1.6/Flutter-AirPlay-0.1.6-android-arm64.apk'}"/>''';

class RealHttpOverrides extends HttpOverrides {}

class RoutingClient implements HttpClient {
  RoutingClient(this.destination)
    : delegate = HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        RealHttpOverrides(),
      );
  final Uri destination;
  final HttpClient delegate;
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) => delegate.getUrl(
    destination.replace(
      path: url.path.endsWith('appcast.xml') ? '/feed' : '/apk',
    ),
  );
  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'Flutter AirPlay',
      packageName: 'tech.soit.flutterairplay',
      version: '0.1.5',
      buildNumber: '4005',
      buildSignature: '',
    ),
  );
  test(
    'uses Android APK build and shared notes regardless of namespace prefix',
    () {
      final update = AndroidAppUpdateService.parseAppcast(
        feed(android: entry()),
      )!;
      expect(update['versionCode'], 4006);
      expect(update['releaseNotes'], '中文 & English');
      expect(update['url'], endsWith('-android-arm64.apk'));
    },
  );

  test(
    'accepts renamed release assets without coupling to publisher filenames',
    () {
      final update = AndroidAppUpdateService.parseAppcast(
        feed(
          android: entry(
            url: 'https://github.com/boyan01/flutter-airplay/releases/download/v0.1.6/AirPlay-universal.apk',
          ),
        ),
      )!;
      expect(update['url'], endsWith('/AirPlay-universal.apk'));
    },
  );

  test('parses appcast produced by release_assets.py including Android extension', () async {
    // Use the existing Python fixture to replace only Sparkle signing/tooling.
    // Both XML generators and changelog encoding execute production code.
    final generated = await Process.run(
      Platform.isWindows ? 'python' : 'python3',
      [
        '-c',
        r"""
import sys
from scripts.tests.test_sparkle_release import SparkleTests, release
case = SparkleTests()
case.setUp()
try:
    (case.root / 'CHANGELOG.md').write_text(
        '## 1.2.3\n### 中文\n- 修复 <script> 与 A&B。\n'
        '### English\n- Fix <script> and A&B.\n')
    feed = case.make_feed()
    apk = case.root / 'Flutter-AirPlay-1.2.3-android-arm64.apk'
    apk.write_bytes(b'APK fixture')
    release.add_android_appcast(feed, apk, '1.2.3', '4004')
    sys.stdout.write(feed.read_text())
finally:
    case.doCleanups()
""",
      ],
    );
    expect(generated.exitCode, 0, reason: generated.stderr.toString());
    final update = AndroidAppUpdateService.parseAppcast(
      generated.stdout as String,
    )!;
    expect(update['version'], '1.2.3');
    expect(update['versionCode'], 4004);
    expect(
      update['url'],
      'https://github.com/boyan01/flutter-airplay/releases/download/v1.2.3/Flutter-AirPlay-1.2.3-android-arm64.apk',
    );
    expect(update['size'], 'APK fixture'.length);
    expect(
      update['sha256'],
      sha256.convert('APK fixture'.codeUnits).toString(),
    );
    expect(
      update['releaseNotes'],
      '中文\n• 修复 <script> 与 A&B。\nEnglish\n• Fix <script> and A&B.',
    );
  });

  test('old macOS-only feed has no Android update', () {
    expect(AndroidAppUpdateService.parseAppcast(feed()), isNull);
  });

  test('rejects ambiguous, malformed or foreign APK metadata', () {
    for (final android in [
      entry() + entry(),
      entry(code: '0'),
      entry(hash: 'invalid'),
      entry(url: 'https://example.com/update.apk'),
      entry(url: 'http://github.com/update.apk'),
      entry(url: 'https://user@github.com/update.apk'),
    ]) {
      expect(
        () => AndroidAppUpdateService.parseAppcast(feed(android: android)),
        throwsFormatException,
      );
    }
  });
  for (final corrupt in [false, true]) {
    test(
      'download verifies checksum and waits for installation (corrupt=$corrupt)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'android-update-test-',
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final bytes = List<int>.generate(100, (index) => index);
        final manifest = feed(
          android: entry(hash: sha256.convert(bytes).toString()),
        );
        var verifies = 0, installs = 0, apkRequests = 0;
        const channel = MethodChannel(
          'tech.soit.flutterairplay/androidUpdates',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'install') {
            verifies++; // No other native call is needed.
          }
          if (call.method == 'install') installs++;
          return null;
        });
        final subscription = server.listen((request) async {
          if (request.uri.path == '/feed') {
            request.response.write(manifest);
          } else {
            apkRequests++;
            request.response.add(corrupt ? List<int>.filled(100, 0) : bytes);
          }
          await request.response.close();
        });
        final service = AndroidAppUpdateService(
          clientFactory: () =>
              RoutingClient(Uri.parse('http://127.0.0.1:${server.port}')),
          temporaryDirectory: () async => directory,
        );
        final finished = Completer<Map<String, dynamic>>();
        service.listen((state) {
          if (['ready', 'error'].contains(state['status']) &&
              !finished.isCompleted) {
            finished.complete(state);
          }
        });
        try {
          await service.initialize();
          expect((await service.checkForUpdates())['status'], 'available');
          expect(apkRequests, 0); // Quiet checks never download an APK.
          expect((await service.installUpdate())['status'], 'downloading');
          final result = await finished.future.timeout(
            const Duration(seconds: 5),
          );
          expect(result['status'], corrupt ? 'error' : 'ready');
          expect(verifies, 0);
          expect(
            installs,
            0,
          ); // Downloads always wait for a separate install action.
          final files = await Directory('${directory.path}/updates')
              .list()
              .toList();
          expect(files.length, corrupt ? 0 : 1);
          if (!corrupt) {
            await service.installUpdate();
            expect(installs, 1);
            expect((await service.showUpdate())['status'], 'ready');
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
