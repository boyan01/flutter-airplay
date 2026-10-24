import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_airplay/ui/tv_focus.dart';

Rect buttonBounds(WidgetTester tester, String key) => tester
    .getRect(
      find
          .descendant(of: find.byKey(Key(key)), matching: find.byType(Material))
          .first,
    )
    .inflate(3);

BoxDecoration ringDecoration(WidgetTester tester) =>
    tester
            .widget<DecoratedBox>(
              find.descendant(
                of: find.byKey(const Key('tvFocusRing')),
                matching: find.byType(DecoratedBox),
              ),
            )
            .decoration
        as BoxDecoration;

void main() {
  testWidgets('one white rounded ring animates between native D-pad targets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TvFocusScope(enabled: true, child: child!),
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton(
                  key: const Key('first'),
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('First'),
                ),
                const SizedBox(width: 80),
                OutlinedButton(
                  key: const Key('second'),
                  onPressed: () {},
                  child: const Text('Second, wider target'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ring = find.byKey(const Key('tvFocusRing'));
    final first = buttonBounds(tester, 'first');
    final second = buttonBounds(tester, 'second');
    expect(tester.getRect(ring), first);
    final decoration = ringDecoration(tester);
    expect(decoration.border, Border.all(color: Colors.white, width: 3));
    expect(decoration.borderRadius, BorderRadius.circular(first.height / 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final moving = tester.getRect(ring);
    expect(moving.left, greaterThan(first.left));
    expect(moving.left, lessThan(second.left));
    expect(ring, findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.getRect(ring), second);
    await tester.binding.setSurfaceSize(const Size(600, 500));
    await tester.pumpAndSettle();
    expect(tester.getRect(ring), buttonBounds(tester, 'second'));
    expect(find.byType(AnimatedScale), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV ring tracks scrolling and does not intercept activation', (
    tester,
  ) async {
    final scroll = ScrollController();
    var activations = 0;
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TvFocusScope(enabled: true, child: child!),
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 120),
                TextButton(
                  key: const Key('action'),
                  autofocus: true,
                  onPressed: () => activations++,
                  child: const Text('Action'),
                ),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ring = find.byKey(const Key('tvFocusRing'));
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(tester.getRect(ring), buttonBounds(tester, 'action'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(activations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabling TV focus preserves the navigator and focused control', (
    tester,
  ) async {
    final enabled = ValueNotifier(false);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, value, _) => TvFocusScope(enabled: value, child: child!),
        ),
        home: Scaffold(
          body: TextButton(
            autofocus: true,
            onPressed: () {},
            child: const Text('Action'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final navigator = tester.state(find.byType(Navigator));
    final focus = FocusManager.instance.primaryFocus;
    enabled.value = true;
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(Navigator)), same(navigator));
    expect(FocusManager.instance.primaryFocus, same(focus));
    expect(find.byKey(const Key('tvFocusRing')), findsOneWidget);
  });

  testWidgets('circle morphs to a list item and retargets during key repeats', (
    tester,
  ) async {
    final first = FocusNode();
    final second = FocusNode();
    final third = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    addTearDown(third.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TvFocusScope(enabled: true, child: child!),
        home: Scaffold(
          body: Column(
            children: [
              IconButton(
                key: const Key('circle'),
                focusNode: first,
                autofocus: true,
                style: IconButton.styleFrom(
                  minimumSize: const Size(120, 56),
                  shape: const CircleBorder(),
                ),
                onPressed: () {},
                icon: const Icon(Icons.settings),
              ),
              const SizedBox(height: 100),
              ListTile(
                key: const Key('item'),
                focusNode: second,
                title: const Text('Settings'),
                onTap: () {},
              ),
              const SizedBox(height: 100),
              TextButton(
                key: const Key('rounded'),
                focusNode: third,
                style: TextButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {},
                child: const Text('Third'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ring = find.byKey(const Key('tvFocusRing'));
    final button = buttonBounds(tester, 'circle').deflate(3);
    final circle = Rect.fromCircle(
      center: button.center,
      radius: button.shortestSide / 2,
    ).inflate(3);
    expect(tester.getRect(ring), circle);
    expect(
      ringDecoration(tester).borderRadius,
      BorderRadius.circular(circle.shortestSide / 2),
    );
    second.requestFocus();
    await tester.idle();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    final moving = tester.getRect(ring);
    final item = tester.getRect(find.byKey(const Key('item'))).inflate(3);
    expect(moving.top, greaterThan(circle.top));
    expect(moving.top, lessThan(item.top));
    final radius =
        (ringDecoration(tester).borderRadius! as BorderRadius).topLeft.x;
    expect(radius, greaterThan(0));
    expect(radius, lessThan(circle.shortestSide / 2));
    third.requestFocus();
    await tester.idle();
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(ring), moving);
    await tester.pumpAndSettle();
    expect(tester.getRect(ring), buttonBounds(tester, 'rounded'));
    expect(ringDecoration(tester).borderRadius, BorderRadius.circular(13));
    second.requestFocus();
    await tester.idle();
    await tester.pumpAndSettle();
    expect(tester.getRect(ring), item);
    expect(ringDecoration(tester).borderRadius, BorderRadius.zero);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('TV focus keeps animating when the system disables motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: TvFocusScope(enabled: true, child: child!),
        ),
        home: Scaffold(
          body: Row(
            children: [
              TextButton(
                key: const Key('first'),
                autofocus: true,
                onPressed: () {},
                child: const Text('First'),
              ),
              const SizedBox(width: 80),
              TextButton(
                key: const Key('second'),
                onPressed: () {},
                child: const Text('Second'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ring = find.byKey(const Key('tvFocusRing'));
    final first = tester.getRect(ring);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getRect(ring).left, greaterThan(first.left));
    expect(
      tester.getRect(ring).left,
      lessThan(buttonBounds(tester, 'second').left),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(ring), buttonBounds(tester, 'second'));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('D-pad scrolling animates and the ring lands on the target', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TvFocusScope(enabled: true, child: child!),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 200,
              child: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    TextButton(
                      autofocus: true,
                      onPressed: () {},
                      child: const Text('Top'),
                    ),
                    const SizedBox(height: 300),
                    TextButton(
                      key: const Key('below'),
                      onPressed: () {},
                      child: const Text('Below'),
                    ),
                    const SizedBox(height: 300),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(scroll.offset, greaterThan(0));
    final scrolling = scroll.offset;
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(scrolling));
    expect(
      tester.getRect(find.byKey(const Key('tvFocusRing'))),
      buttonBounds(tester, 'below'),
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('TvFocus grows compact targets more than wide rows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, value, _) => TvFocusScope(enabled: value, child: child!),
        ),
        home: Scaffold(
          body: Column(
            children: [
              TvFocus(
                child: FilledButton(
                  key: const Key('button'),
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('Start'),
                ),
              ),
              TvFocus(
                child: ListTile(
                  key: const Key('row'),
                  title: const Text('Settings'),
                  onTap: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    Size layoutSize(String key) =>
        tester.renderObject<RenderBox>(find.byKey(Key(key))).size;
    double growth(String key) =>
        tester.getRect(find.byKey(Key(key))).width / layoutSize(key).width;

    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(growth('button'), greaterThan(1));
    expect(growth('button'), lessThan(1.06));
    await tester.pumpAndSettle();
    expect(growth('button'), closeTo(1.06, 0.001));
    expect(
      tester.getRect(find.byKey(const Key('tvFocusRing'))),
      buttonBounds(tester, 'button'),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(growth('button'), 1);
    expect(growth('row'), closeTo(1 + 16 / 800, 0.001));
    expect(
      tester.getRect(find.byKey(const Key('tvFocusRing'))),
      tester.getRect(find.byKey(const Key('row'))).inflate(3),
    );

    enabled.value = false;
    await tester.pumpAndSettle();
    expect(growth('row'), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('scrolling clips the outline without changing its shape', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TvFocusScope(enabled: true, child: child!),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 180,
              child: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    const SizedBox(height: 100),
                    TextButton(
                      key: const Key('action'),
                      autofocus: true,
                      onPressed: () {},
                      child: const Text('Action'),
                    ),
                    const SizedBox(height: 500),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    scroll.jumpTo(120);
    await tester.pump();
    await tester.pump();
    final ring = find.byKey(const Key('tvFocusRing'));
    expect(tester.getRect(ring), buttonBounds(tester, 'action'));
    final clip = tester.widget<ClipRect>(
      find.ancestor(of: ring, matching: find.byType(ClipRect)).first,
    );
    expect(
      clip.clipper!.getClip(const Size(800, 600)),
      tester.getRect(find.byType(SingleChildScrollView)),
    );
    scroll.jumpTo(200);
    await tester.pumpAndSettle();
    expect(ring, findsNothing);
  });

  testWidgets('dialog focus stays on its route and restores the trigger', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TvFocusScope(enabled: true, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const Key('trigger'),
              autofocus: true,
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  actions: [
                    TextButton(
                      key: const Key('close'),
                      autofocus: true,
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final ring = find.byKey(const Key('tvFocusRing'));
    expect(tester.getRect(ring), buttonBounds(tester, 'close'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tester.getRect(ring), buttonBounds(tester, 'trigger'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden custom targets lose the ring and restore their outline', (
    tester,
  ) async {
    final hidden = ValueNotifier(false);
    addTearDown(hidden.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TvFocusScope(enabled: true, child: child!),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: hidden,
            builder: (_, value, _) => Offstage(
              offstage: value,
              child: const TvFocus(
                borderRadius: BorderRadius.zero,
                child: Focus(
                  autofocus: true,
                  child: SizedBox(width: 180, height: 100),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ring = find.byKey(const Key('tvFocusRing'));
    expect(ring, findsOneWidget);
    expect(ringDecoration(tester).borderRadius, BorderRadius.zero);
    hidden.value = true;
    await tester.pumpAndSettle();
    expect(ring, findsNothing);
    hidden.value = false;
    await tester.pumpAndSettle();
    expect(ring, findsOneWidget);
    expect(ringDecoration(tester).borderRadius, BorderRadius.zero);
  });

  testWidgets('non-TV screens keep native focus without a TV ring', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => TvFocusScope(enabled: false, child: child!),
        home: Scaffold(
          body: TvFocus(
            child: TextButton(
              autofocus: true,
              onPressed: () {},
              child: const Text('Action'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tvFocusRing')), findsNothing);
  });
}
