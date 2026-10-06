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
  WidgetStateProperty<BorderSide?> focusBorder(Color color) =>
      WidgetStateProperty.resolveWith(
        (states) => television && states.contains(WidgetState.focused)
            ? BorderSide(color: color, width: 3)
            : null,
      );
  final theme = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff23786e),
      brightness: brightness,
    ),
    fontFamily: systemFonts.familyFor(platform),
    fontFamilyFallback: systemFonts.fallbacksFor(platform),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: Size(64, television ? 56 : 44))
          .copyWith(side: focusBorder(scheme.onPrimary)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(minimumSize: Size(64, television ? 56 : 44))
              .copyWith(
                side: WidgetStateProperty.resolveWith(
                  (states) => BorderSide(
                    color: television && states.contains(WidgetState.focused)
                        ? scheme.primary
                        : scheme.outline,
                    width: television && states.contains(WidgetState.focused)
                        ? 3
                        : 1,
                  ),
                ),
              ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: Size(64, television ? 56 : 44))
          .copyWith(side: focusBorder(scheme.primary)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: Size.square(television ? 56 : 44),
      ).copyWith(side: focusBorder(scheme.primary)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      border: OutlineInputBorder(),
    ),
  );
  return theme.copyWith(
    textTheme: Typography.material2021().englishLike
        .merge(theme.textTheme)
        .apply(fontSizeFactor: television ? 1.25 : 1),
  );
}
