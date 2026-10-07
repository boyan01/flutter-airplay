// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui' as ui;

/// Draws the shared tray mark on a transparent square canvas.
/// Geometry uses a 32-unit grid; render at 2x for high-density menu bars.
Future<ui.Image> createDesktopTrayIcon(ui.Color color, {int size = 64}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(size / 32);
  final paint = ui.Paint()
    ..color = color
    ..strokeWidth = 2.5
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round
    ..style = ui.PaintingStyle.stroke;

  // Leave breathing room between the rounded screen ends and the arrow.
  canvas.drawPath(
    ui.Path()
      ..moveTo(8.5, 22.5)
      ..lineTo(8, 22.5)
      ..quadraticBezierTo(4.5, 22.5, 4.5, 19)
      ..lineTo(4.5, 9)
      ..quadraticBezierTo(4.5, 5.5, 8, 5.5)
      ..lineTo(24, 5.5)
      ..quadraticBezierTo(27.5, 5.5, 27.5, 9)
      ..lineTo(27.5, 19)
      ..quadraticBezierTo(27.5, 22.5, 24, 22.5)
      ..lineTo(23.5, 22.5),
    paint,
  );
  paint.style = ui.PaintingStyle.fill;
  canvas.drawPath(
    ui.Path()
      ..moveTo(15.25, 18.4)
      ..quadraticBezierTo(16, 17.5, 16.75, 18.4)
      ..lineTo(23.4, 26.15)
      ..quadraticBezierTo(24.25, 27.25, 22.75, 27.25)
      ..lineTo(9.25, 27.25)
      ..quadraticBezierTo(7.75, 27.25, 8.6, 26.15)
      ..close(),
    paint,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(size, size);
  } finally {
    picture.dispose();
  }
}
