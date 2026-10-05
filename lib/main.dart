// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mixin_logger/mixin_logger.dart';

import 'app_logging.dart';
import 'receiver/receiver_model.dart';
import 'receiver/receiver_repository.dart';
import 'ui/receiver_screen.dart';
import 'ui/system_fonts.dart';
import 'l10n/generated/app_localizations.dart';

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await initializeLogging();
    final systemFonts = await SystemFonts.initialize();
    LicenseRegistry.addLicense(() async* {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final path in manifest.listAssets().where(
        (path) => path.startsWith('android/app/src/main/assets/licenses/'),
      )) {
        final text = await rootBundle.loadString(path);
        yield LicenseEntryWithLineBreaks([path.split('/').last], text);
      }
    });
    runApp(
      ReceiverApp(
        model: ReceiverModel(NativeReceiverRepository()),
        systemFonts: systemFonts,
      ),
    );
  }, (error, stack) => e('Uncaught application error', error, stack));
}

class ReceiverApp extends StatelessWidget {
  const ReceiverApp({
    super.key,
    required this.model,
    this.systemFonts = const SystemFonts(),
  });
  final ReceiverModel model;
  final SystemFonts systemFonts;

  ThemeData _theme(Brightness brightness) {
    final television = model.isTelevision;
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
      fontFamily: systemFonts.familyFor(model.platform),
      fontFamilyFallback: systemFonts.fallbacksFor(model.platform),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: Size(64, television ? 56 : 44),
        ).copyWith(side: focusBorder(scheme.onPrimary)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style:
            OutlinedButton.styleFrom(
              minimumSize: Size(64, television ? 56 : 44),
            ).copyWith(
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => MaterialApp(
      title: 'Flutter AirPlay',
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.select):
            const ActivateIntent(),
      },
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: model.isTelevision ? ThemeMode.dark : ThemeMode.system,
      home: ReceiverScreen(model: model),
    ),
  );
}
