// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_airplay/app/receiver_app.dart';
import 'package:flutter_airplay/platform/app_updates.dart';
import 'package:flutter_airplay/platform/window_controller.dart';
import 'package:flutter_airplay/platform/windows_app_updates.dart';
import 'package:flutter_airplay/receiver/receiver_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../test/platform/android_app_updates_test.dart' show RoutingClient;
import '../test/receiver/fake_receiver.dart';

class _Preferences extends AppUpdatePreferences {
  @override
  Future<bool> readAutomaticallyCheck() async => true;
  @override
  Future<DateTime?> readLastChecked() async => null;
  @override
  Future<void> writeLastChecked(DateTime value) async {}
}

class _DownloadService extends WindowsAppUpdateService {
  _DownloadService(_Feed fixture)
    : super(
        publicKey: fixture.publicKey,
        clientFactory: () => RoutingClient(fixture.address),
        temporaryDirectory: () async => fixture.directory,
      );

  // The debug test runner is deliberately not a registered release install.
  // Only bypass that enablement gate; retain production feed parsing, signature
  // verification, download lifecycle and the real native installer channel.
  @override
  Future<bool> canEnable() async => true;
}

class _Feed {
  late HttpServer server;
  late Directory directory;
  late String publicKey, manifest;
  final bytes = List<int>.generate(4096, (index) => index % 256);
  final gates = <Completer<void>>[];
  int checks = 0, downloads = 0;
  bool corrupt = false, paused = true;
  Uri get address => Uri.parse('http://127.0.0.1:${server.port}');

  Future<void> start() async {
    directory = await Directory.systemTemp.createTemp('airplay-update-gui-');
    final key = await Ed25519().newKeyPairFromSeed(List.generate(32, (i) => i));
    publicKey = base64Encode((await key.extractPublicKey()).bytes);
    final info = await PackageInfo.fromPlatform();
    final build = int.parse(info.buildNumber) + 1;
    final data = <String, dynamic>{
      'version': '99.0.0',
      'versionCode': build,
      'arch': 'x64',
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
    final signature = await Ed25519().sign(
      WindowsAppUpdateService.signaturePayload(data),
      keyPair: key,
    );
    manifest =
        '''<rss xmlns:a="https://github.com/boyan01/flutter-airplay/updates">
<channel><item><description>&lt;p&gt;中文更新说明 / English release notes&lt;/p&gt;</description>
<a:windows version="99.0.0" build="$build" arch="x64" length="${bytes.length}"
sha256="${data['sha256']}" edSignature="${base64Encode(signature.bytes)}"
url="https://github.com/boyan01/flutter-airplay/releases/download/v99.0.0/setup.exe"/>
</item></channel></rss>''';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        if (request.uri.path == '/feed') {
          checks++;
          request.response.write(manifest);
        } else {
          downloads++;
          final payload = corrupt ? List<int>.filled(bytes.length, 0) : bytes;
          request.response.bufferOutput = false;
          request.response.contentLength = payload.length;
          request.response.add(payload.sublist(0, 1024));
          await request.response.flush();
          if (paused) {
            final gate = Completer<void>();
            gates.add(gate);
            await gate.future;
          }
          request.response.add(payload.sublist(1024));
        }
        await request.response.close();
      } on IOException {
        // Cancellation closes the client while this fixture is streaming.
      }
    });
  }

  void finishDownloads() {
    paused = false;
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<void> close() async {
    finishDownloads();
    await server.close(force: true);
    await directory.delete(recursive: true);
  }
}

Future<void> _wait(
  WidgetTester tester,
  String reason,
  bool Function() matches,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!matches() && DateTime.now().isBefore(deadline)) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(tester.takeException(), isNull, reason: reason);
  }
  expect(matches(), isTrue, reason: reason);
  await tester.pump();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  for (final corrupt in [false, true]) {
    testWidgets(
      'Windows signed update GUI checks, downloads and retries (corrupt=$corrupt)',
      (tester) async {
        final fixture = _Feed()..corrupt = corrupt;
        await fixture.start();
        final updates = AppUpdates(
          service: _DownloadService(fixture),
          preferences: _Preferences(),
          startupDelay: const Duration(milliseconds: 250),
        );
        updates.addListener(() {
          debugPrint(
            'Windows update: status=${updates.status.name}, '
            'progress=${updates.progress}, error=${updates.error}, '
            'checks=${fixture.checks}, downloads=${fixture.downloads}',
          );
        });
        final backend = FakeReceiver(capabilities: {'platform': 'windows'});
        final model = ReceiverModel(backend);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          updates.dispose();
          await backend.controller.close();
          await fixture.close();
        });
        const installer = MethodChannel(
          'tech.soit.flutterairplay/windowsUpdates',
        );
        // This real host must reject installation from the test build, so no
        // executable fixture is launched and no user's installation is changed.
        expect(await installer.invokeMethod<bool>('canUpdate'), isFalse);
        await tester.pumpWidget(ReceiverApp(model: model, updates: updates));
        await const WindowController().withWindow((value) {
          value.show();
          value.focus();
        });
        await _wait(
          tester,
          'scheduled check discovers the signed update',
          () => updates.status == UpdateStatus.available,
        );
        expect(fixture.checks, 1);
        expect(fixture.downloads, 0);
        expect(find.byKey(const Key('appUpdateDialog')), findsNothing);
        expect(updates.releaseNotes, contains('中文更新说明'));

        backend.state('streaming');
        backend.controller.add({
          'type': 'media',
          'audioPlaying': true,
          'videoPaused': false,
        });
        await tester.pumpAndSettle();
        final stops = backend.stops;
        await tester.tap(find.byKey(const Key('appUpdateIndicator')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('appUpdatePrimaryAction')));
        await _wait(
          tester,
          'real download reports partial progress',
          () =>
              updates.status == UpdateStatus.downloading &&
              updates.progress == .25,
        );
        expect(fixture.downloads, 1);
        expect(find.byKey(const Key('appUpdateProgress')), findsOneWidget);
        await tester.tap(find.byKey(const Key('closeAppUpdate')));
        await tester.pump();
        expect(updates.status, UpdateStatus.downloading);
        expect(backend.stops, stops);
        await tester.tap(find.byKey(const Key('appUpdateIndicator')));
        await tester.pump(const Duration(milliseconds: 200));

        if (!corrupt) {
          await tester.tap(find.byKey(const Key('cancelAppUpdate')));
          await _wait(
            tester,
            'cancellation returns to available',
            () => updates.status == UpdateStatus.available,
          );
          fixture.finishDownloads();
          await tester.tap(find.byKey(const Key('appUpdatePrimaryAction')));
        } else {
          fixture.finishDownloads();
          await _wait(
            tester,
            'corrupt download is rejected',
            () => updates.status == UpdateStatus.error,
          );
          expect(updates.error, contains('checksum mismatch'));
          expect(find.textContaining('checksum mismatch'), findsOneWidget);
          final files = await Directory('${fixture.directory.path}/updates')
              .list()
              .toList();
          expect(files, isEmpty);
          fixture.corrupt = false;
          await tester.tap(find.byKey(const Key('appUpdatePrimaryAction')));
        }
        await _wait(
          tester,
          'verified retry waits for explicit installation',
          () => updates.status == UpdateStatus.ready,
        );
        expect(fixture.downloads, 2);
        expect(updates.error, isNull);
        final files = await Directory('${fixture.directory.path}/updates')
            .list()
            .toList();
        expect(files, hasLength(1));
        expect(await (files.single as File).readAsBytes(), fixture.bytes);
        for (var attempt = 0; attempt < 2; attempt++) {
          await tester.tap(find.byKey(const Key('appUpdatePrimaryAction')));
          await _wait(
            tester,
            'native install rejection is shown and retryable',
            () =>
                updates.error?.contains('registered Windows installation') ==
                    true &&
                updates.canInstall,
          );
          expect(updates.status, UpdateStatus.ready);
          expect(
            find.textContaining('registered Windows installation'),
            findsOneWidget,
          );
          expect(fixture.downloads, 2);
        }
        expect(backend.stops, stops);
        expect(model.audioPlaying, isTrue);
        expect(model.status, 'streaming');
      },
      skip: !Platform.isWindows,
    );
  }
}
