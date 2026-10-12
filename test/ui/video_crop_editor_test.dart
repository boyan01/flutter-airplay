import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_airplay/l10n/generated/app_localizations.dart';
import 'package:flutter_airplay/ui/playback/video_crop_editor.dart';
import 'package:flutter_airplay/ui/tv_focus.dart';

void main() {
  const existing = Rect.fromLTWH(.2, .1, .5, .4);
  Rect? applied;
  var cancels = 0;

  Future<void> mount(
    WidgetTester tester, {
    Rect initial = const Rect.fromLTWH(0, 0, 1, 1),
    int width = 1920,
    int height = 1080,
    bool television = false,
    double textScale = 1,
    Size size = const Size(1000, 800),
  }) async {
    applied = null;
    cancels = 0;
    var previewing = false;
    final editorKey = UniqueKey();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: TvFocusScope(enabled: television, child: child!),
        ),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => VideoCropEditor(
              key: editorKey,
              sourceWidth: width,
              sourceHeight: height,
              initialCrop: initial,
              television: television,
              onApply: (rect) => applied = rect,
              onCancel: () => cancels++,
              previewing: previewing,
              onPreviewChanged: (crop) =>
                  setState(() => previewing = crop != null),
              videoBuilder: (_, _) => const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final selection = find.byKey(const Key('cropSelection'));

  Future<Rect> apply(WidgetTester tester) async {
    final button = find.text('Apply crop');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    return applied!;
  }

  testWidgets('new crop fits full video bounds and defaults to centered 16:9', (
    tester,
  ) async {
    await mount(tester, width: 1080, height: 1920);
    final area = tester
        .getRect(find.byKey(const Key('cropEditingArea')))
        .deflate(22);
    final videoWidth = area.height * 1080 / 1920;
    final rect = tester.getRect(selection);
    expect(rect.center, area.center);
    expect(rect.width, closeTo(videoWidth, .001));
    expect(rect.width / rect.height, closeTo(16 / 9, .001));
    final crop = await apply(tester);
    expect(crop.left, 0);
    expect(crop.width, 1);
    expect(crop.center, const Offset(.5, .5));
    expect(crop.width * 1080 / (crop.height * 1920), closeTo(16 / 9, .001));
  });

  testWidgets('existing crop is preserved and movement clamps to source', (
    tester,
  ) async {
    await mount(tester, initial: existing);
    expect(await apply(tester), existing);
    applied = null;
    await tester.drag(selection, const Offset(-600, -600));
    await tester.pump();
    expect(applied, isNull);
    final crop = await apply(tester);
    expect(crop.left, closeTo(0, .001));
    expect(crop.top, closeTo(0, .001));
    expect(crop.width, closeTo(existing.width, .001));
    expect(crop.height, closeTo(existing.height, .001));
  });

  testWidgets('all corner drags keep locked ratio and respect minimum', (
    tester,
  ) async {
    for (var corner = 0; corner < 4; corner++) {
      await mount(tester, initial: const Rect.fromLTWH(.2, .2, .6, .6));
      final before = tester.getRect(selection);
      final handle = find.byKey(Key('cropCorner$corner'));
      await tester.drag(
        handle,
        Offset(corner.isEven ? 90 : -90, corner < 2 ? 70 : -70),
      );
      await tester.pump();
      final after = tester.getRect(selection);
      expect(after.width, lessThan(before.width));
      final crop = await apply(tester);
      expect(crop.width / crop.height, closeTo(1, .001));
      expect(crop.left, greaterThanOrEqualTo(0));
      expect(crop.right, lessThanOrEqualTo(1));
    }
    await tester.drag(
      find.byKey(const Key('cropCorner0')),
      const Offset(1000, 1000),
    );
    await tester.pump();
    final minimum = await apply(tester);
    expect(minimum.width, closeTo(.05, .001));
    expect(minimum.height, closeTo(.05, .001));
  });

  testWidgets('free ratio resizes independently and 16:9 restores ratio', (
    tester,
  ) async {
    await mount(tester, initial: const Rect.fromLTWH(.2, .2, .6, .6));
    await tester.tap(find.byKey(const Key('cropRatio')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Free ratio').last);
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('cropCorner1')),
      const Offset(-100, 0),
    );
    await tester.pump();
    final free = await apply(tester);
    expect(free.width, lessThan(.6));
    expect(free.height, closeTo(.6, .001));
    await tester.tap(find.byKey(const Key('cropRatio')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('16:9').last);
    await tester.pumpAndSettle();
    final locked = await apply(tester);
    expect(locked.width / locked.height, closeTo(1, .001));
  });

  for (final television in [false, true]) {
    testWidgets(
      'ratio menu stays above its whole button and dismisses before editor (TV=$television)',
      (tester) async {
        await mount(tester, television: television);
        final button = find.byKey(const Key('cropRatio'));
        final bounds = tester.getRect(button);
        await tester.tapAt(bounds.topLeft + const Offset(8, 20));
        await tester.pumpAndSettle();
        final free = find.widgetWithText(PopupMenuItem<bool>, 'Free ratio');
        expect(free, findsOneWidget);
        expect(tester.getRect(free).bottom, lessThanOrEqualTo(bounds.top - 8));
        expect(
          find.descendant(
            of: find.widgetWithText(PopupMenuItem<bool>, '16:9'),
            matching: find.byIcon(Icons.check_rounded),
          ),
          findsOneWidget,
        );
        if (television) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          final ring = tester.getRect(find.byKey(const Key('tvFocusRing')));
          final rows = find.byType(PopupMenuItem<bool>);
          expect(
            ring,
            anyOf(
              tester.getRect(rows.at(0)).inflate(3),
              tester.getRect(rows.at(1)).inflate(3),
            ),
          );
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(free, findsNothing);
        expect(cancels, 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(free, findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(free, findsNothing);
        expect(cancels, 0);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester.tap(free);
        await tester.pumpAndSettle();
        expect(applied, isNull);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: free, matching: find.byIcon(Icons.check_rounded)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reset changes only the draft and cancel remains immediate', (
    tester,
  ) async {
    await mount(tester, initial: existing);
    await tester.tap(find.text('Cancel'));
    expect(cancels, 1);
    expect(applied, isNull);
    await tester.tap(find.byKey(const Key('cropReset')));
    await tester.pump();
    expect(find.byType(VideoCropEditor), findsOneWidget);
    expect(applied, isNull);
    expect(await apply(tester), const Rect.fromLTWH(0, 0, 1, 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(cancels, 2);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(cancels, 2);
    expect(find.byType(PopScope), findsNothing);
  });

  testWidgets(
    'TV focus edits only selection and returns to normal button navigation',
    (tester) async {
      await mount(tester, initial: existing, television: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final before = tester.getRect(selection);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(tester.getRect(selection).left, greaterThan(before.left));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final moved = tester.getRect(selection);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(tester.getRect(selection), moved);
      await tester.tap(find.text('Resize frame'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(tester.getRect(selection).width, lessThan(moved.width));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(cancels, 1);
      expect(find.byKey(const Key('tvFocusRing')), findsOneWidget);
    },
  );

  testWidgets('TV taps adjust one source pixel and held arrows move faster', (
    tester,
  ) async {
    await mount(tester, initial: existing, television: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      (await apply(tester)).left,
      closeTo(existing.left + 1 / 1920, .000001),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      (await apply(tester)).top,
      closeTo(existing.top + 9 / 1080, .000001),
    );
  });

  for (final source in [const Size(3840, 2160), const Size(1080, 1920)]) {
    testWidgets(
      'TV fine movement uses source pixels at $source and clamps at edges',
      (tester) async {
        await mount(
          tester,
          initial: existing,
          television: true,
          width: source.width.toInt(),
          height: source.height.toInt(),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        final adjusted = await apply(tester);
        expect(
          adjusted.left,
          closeTo(existing.left - 1 / source.width, .000001),
        );
        expect(
          adjusted.top,
          closeTo(existing.top - 1 / source.height, .000001),
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
        for (var repeat = 0; repeat < 120; repeat++) {
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        final bounded = await apply(tester);
        expect(bounded.left, 0);
        expect(bounded.width, closeTo(adjusted.width, .000001));
        expect(bounded.height, closeTo(adjusted.height, .000001));
      },
    );
  }

  testWidgets('TV resize is precise and repeating confirm keeps tool focus', (
    tester,
  ) async {
    await mount(tester, initial: existing, television: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    final resized = await apply(tester);
    expect(resized.width, closeTo(existing.width - 1 / 1920, .000001));
    expect(resized.height, closeTo(existing.height, .000001));
    expect(resized.center.dx, closeTo(existing.center.dx, .000001));
    expect(resized.center.dy, closeTo(existing.center.dy, .000001));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    final resize = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Resize frame'),
    );
    expect(resize.focusNode!.hasPrimaryFocus, isTrue);
  });

  testWidgets('narrow layout with large text wraps and scrolls all actions', (
    tester,
  ) async {
    await mount(tester, size: const Size(320, 600), textScale: 2.5);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Apply crop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply crop'));
    expect(applied, isNotNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('bottom handles stay inside the editable hit area after reset', (
    tester,
  ) async {
    await mount(tester, width: 1200, height: 900, size: const Size(360, 640));
    expect(find.text('Move frame'), findsNothing);
    expect(find.text('Resize frame'), findsNothing);
    await tester.tap(find.byKey(const Key('cropReset')));
    await tester.pumpAndSettle();
    final area = tester.getRect(find.byKey(const Key('cropEditingArea')));
    for (final handle in ['cropCorner2', 'cropCorner3', 'cropEdge7']) {
      final rect = tester.getRect(find.byKey(Key(handle)));
      expect(area.contains(rect.topLeft), isTrue);
      expect(rect.bottom, lessThanOrEqualTo(area.bottom));
    }
    // Hit the outer half of the bottom handle, beyond the source frame itself.
    final edge = tester.getRect(find.byKey(const Key('cropEdge7')));
    final gesture = await tester.startGesture(
      Offset(edge.center.dx, edge.bottom - 2),
    );
    await gesture.moveBy(const Offset(0, -50));
    await gesture.up();
    await tester.pumpAndSettle();
    final result = await apply(tester);
    expect(result.height, lessThan(1));
    expect(result.width, 1);
    expect(result.top, 0);
  });

  testWidgets('preview preserves layout and Escape returns before canceling', (
    tester,
  ) async {
    await mount(tester, initial: existing);
    final frame = tester.getRect(selection);
    final area = tester.getRect(find.byKey(const Key('cropEditingArea')));
    final applyButton = tester.getRect(find.text('Apply crop'));
    await tester.tap(find.byKey(const Key('cropPreview')));
    await tester.pumpAndSettle();
    expect(selection, findsNothing);
    expect(tester.getRect(find.byKey(const Key('cropEditingArea'))), area);
    expect(tester.getRect(find.text('Apply crop')), applyButton);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.getRect(selection), frame);
    expect(cancels, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(cancels, 1);
  });
}
