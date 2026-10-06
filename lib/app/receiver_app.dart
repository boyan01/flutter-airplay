// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../receiver/receiver_model.dart';
import '../ui/receiver_screen.dart';
import '../ui/widgets/system_fonts.dart';
import '../l10n/generated/app_localizations.dart';
import 'app_theme.dart';

class ReceiverApp extends StatelessWidget {
  const ReceiverApp({
    super.key,
    required this.model,
    this.systemFonts = const SystemFonts(),
  });
  final ReceiverModel model;
  final SystemFonts systemFonts;

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
      theme: receiverTheme(
        Brightness.light,
        television: model.isTelevision,
        platform: model.platform,
        systemFonts: systemFonts,
      ),
      darkTheme: receiverTheme(
        Brightness.dark,
        television: model.isTelevision,
        platform: model.platform,
        systemFonts: systemFonts,
      ),
      themeMode: model.isTelevision ? ThemeMode.dark : ThemeMode.system,
      home: ReceiverScreen(model: model),
    ),
  );
}
