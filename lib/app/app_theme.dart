// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../ui/widgets/system_fonts.dart';

ThemeData receiverTheme(
  Brightness brightness, {
  required bool television,
  required String platform,
  required SystemFonts systemFonts,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff23786e),
    brightness: brightness,
  );
  final focusOverlay = television
      ? WidgetStateProperty.resolveWith<Color?>(
          (states) =>
              states.contains(WidgetState.focused) &&
                  !states.contains(WidgetState.pressed) &&
                  !states.contains(WidgetState.hovered)
              ? Colors.transparent
              : null,
        )
      : null;
  final theme = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff23786e),
      brightness: brightness,
    ),
    focusColor: television ? Colors.transparent : null,
    fontFamily: systemFonts.familyFor(platform),
    fontFamilyFallback: systemFonts.fallbacksFor(platform),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: Size(64, television ? 56 : 44))
          .copyWith(overlayColor: focusOverlay),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(minimumSize: Size(64, television ? 56 : 44))
              .copyWith(
                overlayColor: focusOverlay,
                side: television
                    ? WidgetStateProperty.resolveWith(
                        (states) => BorderSide(
                          color: states.contains(WidgetState.disabled)
                              ? scheme.onSurface.withValues(alpha: .12)
                              : scheme.outline,
                        ),
                      )
                    : null,
              ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: Size(64, television ? 56 : 44))
          .copyWith(overlayColor: focusOverlay),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: Size.square(television ? 56 : 44),
      ).copyWith(overlayColor: focusOverlay),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      border: const OutlineInputBorder(),
      focusedBorder: television
          ? OutlineInputBorder(borderSide: BorderSide(color: scheme.outline))
          : null,
    ),
  );
  return theme.copyWith(
    textTheme: Typography.material2021().englishLike
        .merge(theme.textTheme)
        .apply(fontSizeFactor: television ? 1.25 : 1),
  );
}
