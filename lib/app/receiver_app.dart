// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../receiver/receiver_model.dart';
import '../platform/window_controller.dart';
import '../platform/launch_at_login.dart';
import '../ui/receiver_screen.dart';
import '../ui/widgets/desktop_window_bar.dart';
import '../ui/widgets/control_interaction_region.dart';
import '../ui/tv_focus.dart';
import '../ui/widgets/system_fonts.dart';
import '../l10n/generated/app_localizations.dart';
import 'app_theme.dart';

class ReceiverApp extends StatefulWidget {
  const ReceiverApp({
    super.key,
    required this.model,
    this.launchAtLogin = const LaunchAtLogin(),
    this.systemFonts = const SystemFonts(),
    this.window = const WindowController(),
  });
  final ReceiverModel model;
  final LaunchAtLogin launchAtLogin;
  final WindowController window;
  final SystemFonts systemFonts;

  @override
  State<ReceiverApp> createState() => _ReceiverAppState();
}

class _ReceiverAppState extends State<ReceiverApp> {
  bool _controlsVisible = false, _dialogOpen = false, _expanded = false;
  bool _hadVideo = false;
  final _titleInteraction = ValueNotifier(false);
  ReceiverModel get model => widget.model;
  WindowController get window => widget.window;
  SystemFonts get systemFonts => widget.systemFonts;

  @override
  void initState() {
    super.initState();
    _hadVideo = model.hasVideo;
    model.addListener(_modeChanged);
  }

  void _modeChanged() {
    if (_hadVideo == model.hasVideo) return;
    _hadVideo = model.hasVideo;
    _controlsVisible = false;
    _titleInteraction.value = false;
  }

  @override
  void dispose() {
    model.removeListener(_modeChanged);
    _titleInteraction.dispose();
    super.dispose();
  }

  Widget _shell(BuildContext context, Widget child) {
    final desktop = model.supportsWindowPreferences;
    return TvFocusScope(
      enabled: model.isTelevision,
      child: Overlay.wrap(
        child: CallbackShortcuts(
          bindings: {
            if ({'windows', 'linux'}.contains(model.platform)) ...{
              const SingleActivator(
                LogicalKeyboardKey.f11,
                includeRepeats: false,
              ): () =>
                  window.execute(WindowCommand.toggleFullscreen),
              const SingleActivator(
                LogicalKeyboardKey.escape,
                includeRepeats: false,
              ): () {
                if (!_dialogOpen) window.execute(WindowCommand.exitFullscreen);
              },
              const SingleActivator(
                LogicalKeyboardKey.keyW,
                control: true,
                includeRepeats: false,
              ): () =>
                  window.execute(WindowCommand.closeWindow),
              const SingleActivator(
                LogicalKeyboardKey.keyQ,
                control: true,
                includeRepeats: false,
              ): () =>
                  window.execute(WindowCommand.quitApp),
            },
          },
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(
                  top: desktop && (!model.hasVideo || _dialogOpen)
                      ? DesktopWindowBar.height
                      : 0,
                ),
                child: child,
              ),
              if (desktop &&
                  (!model.hasVideo || _controlsVisible || _dialogOpen))
                Positioned(
                  top: MediaQuery.paddingOf(context).top,
                  left: 0,
                  right: 0,
                  child: Material(
                    color: model.hasVideo
                        ? Colors.black
                        : Theme.of(context).scaffoldBackgroundColor,
                    child: ControlInteractionRegion(
                      onChanged: (active) {
                        _titleInteraction.value = active;
                      },
                      child: DesktopWindowBar(
                        window: window,
                        platform: model.platform,
                        title: model.hasVideo
                            ? model.clientName ?? 'iPhone'
                            : 'Flutter AirPlay',
                        dark: model.hasVideo,
                        maximized: _expanded,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => MaterialApp(
      builder: (context, child) => _shell(context, child!),
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
      home: ReceiverScreen(
        model: model,
        controlsInteraction: _titleInteraction,
        launchAtLogin: widget.launchAtLogin,
        window: window,
        onControlsVisibility: (visible) {
          // Removed regions do not receive MouseRegion.onExit or focus callbacks.
          if (!visible) _titleInteraction.value = false;
          if (mounted && _controlsVisible != visible) {
            setState(() => _controlsVisible = visible);
          }
        },
        onDialogVisibility: (visible) {
          if (mounted && _dialogOpen != visible) {
            setState(() => _dialogOpen = visible);
          }
        },
        onWindowExpanded: (expanded) {
          if (mounted && _expanded != expanded) {
            setState(() => _expanded = expanded);
          }
        },
      ),
    ),
  );
}
