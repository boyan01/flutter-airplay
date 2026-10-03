// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'receiver/receiver_model.dart';
import 'receiver/receiver_repository.dart';
import 'ui/receiver_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ReceiverApp(model: ReceiverModel(NativeReceiverRepository())));
}

class ReceiverApp extends StatefulWidget {
  const ReceiverApp({super.key, required this.model});
  final ReceiverModel model;

  @override
  State<ReceiverApp> createState() => _ReceiverAppState();
}

class _ReceiverAppState extends State<ReceiverApp> {
  ThemeMode _themeMode = ThemeMode.system;

  ThemeData _theme(Brightness brightness) {
    final television = widget.model.isTelevision;
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
      fontFamily: widget.model.platform == 'macos'
          ? '.AppleSystemUIFont'
          : null,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: Size(64, television ? 56 : 44),
        ).copyWith(side: focusBorder(scheme.onPrimary)),
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
    listenable: widget.model,
    builder: (context, _) => MaterialApp(
      title: 'Flutter AirPlay',
      debugShowCheckedModeBanner: false,
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _themeMode,
      home: ReceiverScreen(
        model: widget.model,
        themeMode: _themeMode,
        onThemeChanged: (mode) => setState(() => _themeMode = mode),
      ),
    ),
  );
}
