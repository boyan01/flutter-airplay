import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_airplay/l10n/generated/app_localizations.dart';
import 'package:flutter_airplay/platform/launch_at_login.dart';
import 'package:flutter_airplay/ui/settings/launch_at_login_tile.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeLogin extends LaunchAtLogin {
  bool enabled = false, failRead = false, failWrite = false, pending = false;
  bool approvalRequired = false;
  int writes = 0;
  Completer<void>? wait;
  @override
  Future<bool> isEnabled() async {
    if (approvalRequired) throw PlatformException(code: 'approval_required');
    if (failRead) throw PlatformException(code: 'denied');
    return enabled;
  }

  @override
  Future<bool> setEnabled(bool value) async {
    writes++;
    await wait?.future;
    if (failWrite) throw PlatformException(code: 'denied');
    if (!value) approvalRequired = false;
    if (!pending) enabled = value;
    return enabled;
  }
}

void main() {
  Future<void> open(WidgetTester tester, FakeLogin fake) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: LaunchAtLoginTile(service: fake)),
      ),
    );
    await tester.pumpAndSettle();
  }

  SwitchListTile tile(WidgetTester tester) =>
      tester.widget(find.byKey(const Key('launchAtLogin')));

  testWidgets('opening only reads OS; toggling round trips actual state', (
    tester,
  ) async {
    final fake = FakeLogin();
    await open(tester, fake);
    expect(fake.writes, 0);
    expect(tile(tester).value, false);
    await tester.tap(find.byKey(const Key('launchAtLogin')));
    await tester.pumpAndSettle();
    expect(tile(tester).value, true);
    await tester.tap(find.byKey(const Key('launchAtLogin')));
    await tester.pumpAndSettle();
    expect(tile(tester).value, false);
  });
  testWidgets('duplicate taps disabled while pending; disposal is safe', (
    tester,
  ) async {
    final fake = FakeLogin()..wait = Completer<void>();
    await open(tester, fake);
    await tester.tap(find.byKey(const Key('launchAtLogin')));
    await tester.pump();
    expect(tile(tester).onChanged, null);
    await tester.tap(find.byKey(const Key('launchAtLogin')));
    expect(fake.writes, 1);
    await tester.pumpWidget(const SizedBox());
    fake.wait!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), null);
  });
  testWidgets('write errors reconcile; pending approval never looks enabled', (
    tester,
  ) async {
    final fake = FakeLogin()..failWrite = true;
    await open(tester, fake);
    await tester.tap(find.byKey(const Key('launchAtLogin')));
    await tester.pumpAndSettle();
    expect(tile(tester).value, false);
    expect(find.textContaining('Unable to read or change'), findsOneWidget);
    fake
      ..failWrite = false
      ..pending = true;
    await tester.tap(find.byKey(const Key('launchAtLogin')));
    await tester.pumpAndSettle();
    expect(tile(tester).value, false);
    expect(find.textContaining('has not applied'), findsOneWidget);
  });
  testWidgets('unknown read state disables toggle and refresh recovers', (
    tester,
  ) async {
    final fake = FakeLogin()..failRead = true;
    await open(tester, fake);
    expect(tile(tester).onChanged, null);
    fake
      ..failRead = false
      ..enabled = true;
    await tester.tap(find.byKey(const Key('refreshLogin')));
    await tester.pumpAndSettle();
    expect(tile(tester).value, true);
    expect(tile(tester).onChanged, isNotNull);
    expect(fake.writes, 0);
  });
  testWidgets('approval pending after reopening can be cancelled', (
    tester,
  ) async {
    final fake = FakeLogin()..approvalRequired = true;
    await open(tester, fake);
    expect(tile(tester).value, false);
    expect(find.byKey(const Key('cancelLoginRequest')), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancelLoginRequest')));
    await tester.pumpAndSettle();
    expect(fake.approvalRequired, false);
    expect(fake.writes, 1);
    expect(find.byKey(const Key('cancelLoginRequest')), findsNothing);
  });
  testWidgets('resume reads external changes without rewriting them', (
    tester,
  ) async {
    final fake = FakeLogin();
    await open(tester, fake);
    fake.enabled = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tile(tester).value, true);
    expect(fake.writes, 0);
  });
}
