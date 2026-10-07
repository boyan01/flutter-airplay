// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui' as ui;

import 'package:flutter_airplay/platform/desktop_tray_icon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'tray mark keeps transparent padding and screen at desktop sizes',
    () async {
      for (final size in [16, 18, 20, 22, 24, 32, 44, 64]) {
        final image = await createDesktopTrayIcon(
          const ui.Color(0xff32958a),
          size: size,
        );
        expect(image.width, size);
        expect(image.height, size);
        final bytes = (await image.toByteData())!.buffer.asUint8List();
        int alpha(int x, int y) => bytes[(y * size + x) * 4 + 3];
        for (var p = 0; p < size; p++) {
          expect(alpha(p, 0), 0);
          expect(alpha(p, size - 1), 0);
          expect(alpha(0, p), 0);
          expect(alpha(size - 1, p), 0);
        }
        // Screen interior stays open; the receiver arrow stays visible.
        expect(alpha(size ~/ 2, (size * 12 / 32).floor()), 0);
        expect(alpha(size ~/ 2, (size * 24 / 32).floor()), 255);
        // Curved-edge antialiasing may differ slightly between scan directions.
        // Keep the alpha mask symmetric to within 1/16 of full opacity.
        for (var y = 0; y < size; y++) {
          for (var x = 0; x < size ~/ 2; x++) {
            expect(
              (alpha(x, y) - alpha(size - 1 - x, y)).abs(),
              lessThanOrEqualTo(16),
            );
          }
        }
        image.dispose();
      }
    },
  );

  test('all state colors share the same template alpha mask', () async {
    List<int>? mask;
    for (final color in [
      0xffa0a9ae,
      0xff32958a,
      0xffe4b55e,
      0xff20bfa9,
      0xfff06a6a,
    ]) {
      final image = await createDesktopTrayIcon(ui.Color(color));
      expect(image.width, 64);
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      final alpha = [for (var i = 3; i < bytes.length; i += 4) bytes[i]];
      if (mask != null) expect(alpha, mask);
      mask = alpha;
      final center = (48 * 64 + 32) * 4;
      expect(bytes.sublist(center, center + 4), [
        (color >> 16) & 255,
        (color >> 8) & 255,
        color & 255,
        255,
      ]);
      image.dispose();
    }
  });
}
