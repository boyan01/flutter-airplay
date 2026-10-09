import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_airplay/app/app_theme.dart';
import 'package:flutter_airplay/l10n/generated/app_localizations.dart';
import 'package:flutter_airplay/platform/app_updates.dart';
import 'package:flutter_airplay/ui/updates/app_update_dialog.dart';
import 'package:flutter_airplay/ui/tv_focus.dart';
import 'package:flutter_airplay/ui/widgets/system_fonts.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeService extends AppUpdateService {
  @override
  void listen(ValueChanged<Map<String, dynamic>>? listener) {}
}

class _FakeUpdates extends AppUpdates {
  _FakeUpdates() : super(service: _FakeService()) {
    initialized = supported = enabled = true;
  }

  bool allowInstall = true,
      allowCancel = true,
      allowCheck = true,
      allowShow = true;
  int installs = 0, cancels = 0, checks = 0, shows = 0;

  @override
  bool get canInstall => enabled && allowInstall;
  @override
  bool get canCancel => enabled && allowCancel;
  @override
  bool get canCheck => enabled && allowCheck;
  @override
  bool get canShowUpdate => enabled && allowShow;

  @override
  Future<void> install() async {
    installs++;
    status = status == UpdateStatus.ready
        ? UpdateStatus.installing
        : UpdateStatus.downloading;
    notifyListeners();
  }

  @override
  Future<void> cancel() async {
    cancels++;
    status = UpdateStatus.available;
    notifyListeners();
  }

  @override
  Future<void> check() async {
    checks++;
    status = UpdateStatus.checking;
    notifyListeners();
  }

  @override
  Future<void> showUpdate() async {
    shows++;
  }

  void publish() => notifyListeners();
}

void main() {
  Future<void> open(
    WidgetTester tester,
    _FakeUpdates updates, {
    bool connected = false,
    bool television = false,
    Locale locale = const Locale('en'),
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            TvFocusScope(enabled: television, child: child!),
        shortcuts: {
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.select):
              const ActivateIntent(),
        },
        theme: theme,
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('openUpdate'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AppUpdateDialog(
                  updates: updates,
                  currentVersion: '1.0.0',
                  connected: connected,
                  television: television,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('openUpdate')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      updates.dispose();
    });
  }

  FilledButton primary(WidgetTester tester) =>
      tester.widget(find.byKey(const Key('appUpdatePrimaryAction')));

  Finder dialogSurface() => find
      .descendant(
        of: find.byKey(const Key('appUpdateDialog')),
        matching: find.byType(Material),
      )
      .first;

  testWidgets(
    'TV remote scrolls notes with fixed actions and Back preserves download',
    (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final updates = _FakeUpdates()
        ..status = UpdateStatus.available
        ..version = '0.1.6'
        ..releaseNotes = List.generate(
          40,
          (index) => 'Release note $index',
        ).join('\n');
      await open(tester, updates, television: true);
      final primaryFinder = find.byKey(const Key('appUpdatePrimaryAction'));
      expect(tester.getRect(primaryFinder).bottom, lessThan(360));
      expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<IconButton>()
            ?.key,
        const Key('closeAppUpdate'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final contentFocus = Focus.of(
        tester.element(find.byKey(const Key('appUpdateReleaseNotes'))),
      );
      expect(contentFocus.hasPrimaryFocus, isTrue);
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('appUpdateDialog')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(scrollable.position.pixels, greaterThan(0));
      expect(tester.getRect(primaryFinder).bottom, lessThan(360));
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(contentFocus.hasPrimaryFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(updates.installs, 1);
      expect(find.byKey(const Key('cancelAppUpdate')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdateDialog), findsNothing);
      expect(updates.status, UpdateStatus.downloading);
      expect(updates.cancels, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android installation uses system confirmation text without restart promise',
    (tester) async {
      final updates = _FakeUpdates()
        ..requiresSystemInstall = true
        ..status = UpdateStatus.ready
        ..version = '0.1.6';
      addTearDown(updates.dispose);
      await open(tester, updates, connected: true);
      expect(find.text('Install update'), findsOneWidget);
      expect(find.text('Install and restart'), findsNothing);
      expect(
        find.textContaining('Android will ask you to confirm installation.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Installing this update will interrupt the current AirPlay connection and close Flutter AirPlay.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('available update downloads and renders release notes as text', (
    tester,
  ) async {
    final updates = _FakeUpdates()
      ..status = UpdateStatus.available
      ..version = '2.1.0'
      ..releaseNotes = '<b>Faster playback</b>\nBug fixes';
    await open(tester, updates);
    expect(find.text('App updates'), findsOneWidget);
    expect(find.text('Current version 1.0.0'), findsOneWidget);
    expect(find.text('Version 2.1.0 is available'), findsOneWidget);
    expect(find.text('<b>Faster playback</b>\nBug fixes'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(tester.getSize(dialogSurface()).width, 400);
    expect(
      primary(tester).style!.shape!.resolve({}),
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );
    await tester.tap(find.byKey(const Key('appUpdatePrimaryAction')));
    await tester.pump();
    expect(updates.installs, 1);
    expect(updates.status, UpdateStatus.downloading);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets(
    'information-only updates explain why installation is unavailable',
    (tester) async {
      final updates = _FakeUpdates()
        ..status = UpdateStatus.available
        ..version = '2.1.0'
        ..allowInstall = false
        ..unavailableReason =
            'This update cannot be installed in the application.';
      await open(tester, updates);
      expect(find.text(updates.unavailableReason!), findsOneWidget);
      expect(primary(tester).onPressed, isNull);
    },
  );

  testWidgets('download exposes cancel and close continues in background', (
    tester,
  ) async {
    final updates = _FakeUpdates()
      ..status = UpdateStatus.downloading
      ..version = '2.1.0'
      ..progress = 0.42;
    await open(tester, updates);
    expect(find.text('Downloading update… 42%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('appUpdateProgress')),
          )
          .value,
      0.42,
    );
    expect(find.textContaining('continue in the background'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byKey(const Key('cancelAppUpdate')), findsOneWidget);
    await tester.tap(find.byKey(const Key('closeAppUpdate')));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateDialog), findsNothing);
    expect(updates.cancels, 0);
    expect(updates.status, UpdateStatus.downloading);
    await tester.tap(find.byKey(const Key('openUpdate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancelAppUpdate')));
    await tester.pumpAndSettle();
    expect(updates.cancels, 1);
    expect(updates.status, UpdateStatus.available);
    expect(find.byType(AppUpdateDialog), findsOneWidget);
    expect(find.text('Download update'), findsOneWidget);
  });

  testWidgets('ready update warns about connection and installs once', (
    tester,
  ) async {
    final updates = _FakeUpdates()
      ..status = UpdateStatus.ready
      ..version = '2.1.0';
    await open(tester, updates, connected: true);
    expect(find.byKey(const Key('updateInterruptWarning')), findsOneWidget);
    expect(find.text('Install and restart'), findsOneWidget);
    await tester.tap(find.byKey(const Key('appUpdatePrimaryAction')));
    await tester.pump();
    expect(updates.installs, 1);
    expect(updates.status, UpdateStatus.installing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('Installing update…'), findsOneWidget);
  });

  testWidgets('later and Escape dismiss without installing or cancelling', (
    tester,
  ) async {
    final updates = _FakeUpdates()
      ..status = UpdateStatus.ready
      ..version = '2.1.0';
    await open(tester, updates);
    expect(find.byKey(const Key('updateInterruptWarning')), findsNothing);
    await tester.tap(find.byKey(const Key('deferAppUpdate')));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateDialog), findsNothing);
    await tester.tap(find.byKey(const Key('openUpdate')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateDialog), findsNothing);
    expect(updates.installs, 0);
    expect(updates.cancels, 0);
  });

  testWidgets('keyboard activates download action', (tester) async {
    final updates = _FakeUpdates()
      ..status = UpdateStatus.available
      ..version = '2.1.0';
    await open(tester, updates);
    for (var index = 0; index < 3; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(updates.installs, 1);
  });

  for (final retry in ['install', 'check', 'show']) {
    testWidgets('error retry follows host $retry capability', (tester) async {
      final updates = _FakeUpdates()
        ..status = UpdateStatus.error
        ..version = retry == 'check' ? null : '2.1.0'
        ..error = 'Update request failed'
        ..allowInstall = retry == 'install'
        ..allowCheck = retry == 'check'
        ..allowShow = retry == 'show';
      await open(tester, updates);
      expect(find.text('Update request failed'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.byKey(const Key('appUpdatePrimaryAction')));
      await tester.pump();
      expect(updates.installs, retry == 'install' ? 1 : 0);
      expect(updates.checks, retry == 'check' ? 1 : 0);
      expect(updates.shows, retry == 'show' ? 1 : 0);
    });
  }

  testWidgets(
    'narrow dark dialog scrolls large text and long notes to actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 480));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final updates = _FakeUpdates()
        ..status = UpdateStatus.ready
        ..version = '2.1.0'
        ..releaseNotes = List.filled(
          20,
          'Improved playback and connection recovery.',
        ).join('\n');
      await open(
        tester,
        updates,
        connected: true,
        locale: const Locale('zh'),
        theme: receiverTheme(
          Brightness.dark,
          television: false,
          platform: 'macos',
          systemFonts: const SystemFonts(),
        ),
      );
      expect(tester.getSize(dialogSurface()).width, 288);
      await tester.ensureVisible(
        find.byKey(const Key('appUpdatePrimaryAction')),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('appUpdatePrimaryAction')));
      await tester.pump();
      expect(updates.installs, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('idle checks once and checking only offers dismissal', (
    tester,
  ) async {
    final updates = _FakeUpdates();
    await open(tester, updates);
    expect(find.byType(FilledButton), findsOneWidget);
    await tester.tap(find.byKey(const Key('appUpdatePrimaryAction')));
    await tester.pump();
    expect(updates.checks, 1);
    expect(find.text('Checking for updates…'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byKey(const Key('deferAppUpdate')), findsOneWidget);
    await tester.tap(find.byKey(const Key('deferAppUpdate')));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateDialog), findsNothing);
  });

  testWidgets('unknown progress and preparing state retain a close action', (
    tester,
  ) async {
    final updates = _FakeUpdates()
      ..status = UpdateStatus.downloading
      ..version = '2.1.0';
    await open(tester, updates);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('appUpdateProgress')),
          )
          .value,
      isNull,
    );
    updates.status = UpdateStatus.extracting;
    updates.publish();
    await tester.pump();
    expect(find.text('Preparing update…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    await tester.tap(find.byKey(const Key('closeAppUpdate')));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdateDialog), findsNothing);
    expect(updates.cancels, 0);
  });
}
