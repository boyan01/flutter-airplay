import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_airplay/ui/tv_focus.dart';

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
    final first = tester.getRect(find.byKey(const Key('first'))).inflate(3);
    final second = tester.getRect(find.byKey(const Key('second'))).inflate(3);
    expect(tester.getRect(ring), first);
    final decoration =
        tester.widget<DecoratedBox>(ring).decoration as BoxDecoration;
    expect(decoration.border, Border.all(color: Colors.white, width: 3));
    expect(decoration.borderRadius, BorderRadius.circular(12));
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
    expect(
      tester.getRect(ring),
      tester.getRect(find.byKey(const Key('second'))).inflate(3),
    );
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
    expect(
      tester.getRect(ring),
      tester.getRect(find.byKey(const Key('action'))).inflate(3),
    );
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
