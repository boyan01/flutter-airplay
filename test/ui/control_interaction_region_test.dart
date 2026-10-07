// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_airplay/ui/widgets/control_interaction_region.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'pointer capture holds chrome after exit until cancel or release',
    (tester) async {
      final changes = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: ControlInteractionRegion(
              onChanged: changes.add,
              child: const SizedBox(width: 100, height: 100),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(20, 20));
      await tester.pump();
      expect(changes, [true]);
      await mouse.down(const Offset(20, 20));
      await mouse.moveTo(const Offset(200, 200));
      await tester.pump(const Duration(seconds: 4));
      expect(changes, [true]);
      await mouse.cancel();
      await tester.pump();
      expect(changes, [true, false]);
      await mouse.removePointer();
    },
  );

  testWidgets('touch release does not leave a synthetic hover hold', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: ControlInteractionRegion(
            onChanged: changes.add,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    final touch = await tester.startGesture(const Offset(20, 20));
    await tester.pump();
    expect(changes, [true]);
    await touch.up();
    await tester.pump();
    expect(changes, [true, false]);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
