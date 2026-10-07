// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app/app_logging.dart';
import '../receiver/receiver_model.dart';
import '../platform/window_controller.dart';
import '../platform/launch_at_login.dart';
import '../platform/desktop_presentation.dart';
import 'widgets/receiver_strings.dart';
import 'home/home_page.dart';
import 'playback/audio_page.dart';
import 'playback/player_page.dart';
import 'settings/settings_page.dart';
import 'logs/logs_page.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({
    super.key,
    required this.model,
    this.launchAtLogin = const LaunchAtLogin(),
    this.window = const WindowController(),
    this.onControlsVisibility,
    this.controlsInteraction,
    this.onDialogVisibility,
    this.onWindowExpanded,
  });
  final ReceiverModel model;
  final ValueListenable<bool>? controlsInteraction;
  final LaunchAtLogin launchAtLogin;
  final WindowController window;
  final ValueChanged<bool>? onControlsVisibility,
      onDialogVisibility,
      onWindowExpanded;

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  WindowController get _window => widget.window;
  final _homeFocus = FocusNode(debugLabel: 'Home action');
  bool _dialogOpen = false;
  late final DesktopPresentation _desktop;
  bool _playing = false;
  String _orientationMode = '';
  bool _connected = false;
  String _homeAction = '';
  double _displayRefreshRate = 60;
  late final FlutterFrameDiagnostics _frameDiagnostics;
  ReceiverModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _frameDiagnostics = FlutterFrameDiagnostics(
      isPlaying: () => mounted && model.hasVideo && !model.videoPaused,
      refreshRate: () => _displayRefreshRate,
    );
    _desktop = DesktopPresentation(
      window: _window,
      model: model,
      onAction: _windowAction,
      onError: _windowError,
    );
    _window.listen(_windowAction);
    model.addListener(_changed);
    model.initialize();
  }

  Future<void> _windowAction(WindowAction action, bool expanded) async {
    try {
      if (!mounted) return;
      if (action == WindowAction.quitApp) {
        await _window.execute(WindowCommand.quitApp);
      } else if (action == WindowAction.openApp) {
        await _desktop.show();
      } else if (action == WindowAction.closeRequested) {
        await _desktop.hide(
          disconnect: model.hasVideo || model.status == 'streaming',
        );
      } else if (action == WindowAction.actualSize) {
        await _desktop.resize(actualSize: true);
      } else if (action == WindowAction.fitScreen) {
        await _desktop.resize();
      } else if (action == WindowAction.windowTransitionStarted) {
        _desktop.transitionStarted();
      } else if (action == WindowAction.openSettings) {
        if (model.supportsWindowPreferences) await _desktop.show();
        await _settings();
      } else if (action == WindowAction.openLogs) {
        if (model.supportsWindowPreferences) await _desktop.show();
        await _logs();
      } else if (action == WindowAction.toggleReceiver) {
        if (model.canStop) {
          await model.stop();
        } else if (model.canStart) {
          await model.start(model.name, model.path);
        }
      } else if (action == WindowAction.disconnectSession) {
        await model.disconnect();
      } else if (action == WindowAction.toggleOnTop) {
        await model.save(
          model.name,
          model.path,
          desktopOptions: {
            ...model.desktopOptions,
            'alwaysOnTop': !model.desktopOptions['alwaysOnTop']!,
          },
        );
      } else if (action == WindowAction.toggleFullscreen) {
        await _toggleFullscreen();
      } else if (action == WindowAction.enterFullscreen) {
        await _toggleFullscreen(target: true);
      } else if (action == WindowAction.minimizeWindow) {
        await _window.execute(WindowCommand.minimizeWindow);
      } else if (action == WindowAction.toggleMaximize) {
        await _window.execute(WindowCommand.toggleMaximize);
      } else if (action == WindowAction.windowStateChanged ||
          action == WindowAction.nativeWindowStateChanged) {
        final current = await _desktop.stateChanged(
          transitionCompleted: action == WindowAction.windowStateChanged,
        );
        widget.onWindowExpanded?.call(expanded || current);
      }
    } on MissingPluginException {
      // Widget tests do not have a desktop host.
    } on PlatformException catch (error) {
      _windowError(error);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _displayRefreshRate = View.of(context).display.refreshRate;
    _updateDesktop();
  }

  Future<void> _updateDesktop() async {
    if (!mounted) return;
    try {
      await _desktop.update(
        l10n(context),
        reduceMotion: MediaQuery.disableAnimationsOf(context),
      );
    } on MissingPluginException {
      // Widget tests do not have a desktop host.
    } on PlatformException catch (error) {
      _windowError(error);
    }
  }

  void _windowError(PlatformException error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.message ?? l10n(context).fullscreenFailed)),
    );
  }

  void _changed() {
    _updateDesktop();
    final playing = model.hasVideo;
    if (model.loaded && model.platform == 'android') {
      final mode = '$playing:${model.videoWidth}:${model.videoHeight}';
      if (_orientationMode != mode) {
        _orientationMode = mode;
        _updateOrientation(playing);
      }
    }
    if (playing != _playing) {
      _playing = playing;
      if (model.platform == 'android') {
        SystemChrome.setEnabledSystemUIMode(
          playing ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      }
    }
    final connected = model.status == 'streaming';
    if (_connected && !connected && model.isTelevision) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n(context).sessionEnded),
              duration: Duration(seconds: 3),
            ),
          );
        }
      });
    }
    _connected = connected;
    final action = playing
        ? 'player'
        : model.showAudioPage
        ? 'audioSettings'
        : model.canStart
        ? 'start'
        : 'settings';
    if (model.loaded && action != _homeAction) {
      _homeAction = action;
      if (!playing) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _restoreFocus());
      }
    }
  }

  Future<void> _updateOrientation(bool playing) async {
    try {
      await _window.setPlaybackOrientation(
        playing: playing,
        width: model.videoWidth,
        height: model.videoHeight,
      );
    } on MissingPluginException {
      // Widget tests do not have an Android host.
    } on PlatformException catch (error) {
      _windowError(error);
    }
  }

  void _restoreFocus() {
    if (mounted && !_dialogOpen && !model.hasVideo) _homeFocus.requestFocus();
  }

  void _toggleReceiver() {
    if (_dialogOpen) return;
    if (model.canStop) {
      model.stop();
    } else if (model.canStart) {
      model.start(model.name, model.path);
    }
  }

  Future<void> _toggleFullscreen({bool? target}) async {
    if (!{'macos', 'windows', 'linux'}.contains(model.platform)) return;
    try {
      await _window.execute(switch (target) {
        true => WindowCommand.enterFullscreen,
        false => WindowCommand.exitFullscreen,
        null => WindowCommand.toggleFullscreen,
      });
    } on MissingPluginException {
      // A widget-test host has no native window.
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.message ?? l10n(context).fullscreenFailed),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _frameDiagnostics.dispose();
    _window.listen(null);
    _desktop.dispose();
    unawaited(_window.releaseNativeWindow());
    model.removeListener(_changed);
    _homeFocus.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => CallbackShortcuts(
      bindings: {
        if ({'windows', 'linux'}.contains(model.platform)) ...{
          const SingleActivator(LogicalKeyboardKey.keyR, control: true):
              _toggleReceiver,
          const SingleActivator(LogicalKeyboardKey.comma, control: true):
              _settings,
          const SingleActivator(LogicalKeyboardKey.keyL, control: true): _logs,
          const SingleActivator(LogicalKeyboardKey.period, control: true): () {
            if (!_dialogOpen && model.status == 'streaming') model.disconnect();
          },
        },
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            _toggleReceiver,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): _settings,
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true): _logs,
        const SingleActivator(LogicalKeyboardKey.period, meta: true): () {
          if (!_dialogOpen && model.status == 'streaming') model.disconnect();
        },
      },
      child: Scaffold(
        backgroundColor: model.hasVideo
            ? model.usesNativeVideo
                  ? Colors.transparent
                  : Colors.black
            : null,
        body: model.hasVideo
            ? PlayerPage(
                model: model,
                onFullscreen: _toggleFullscreen,
                onEscape: () => _toggleFullscreen(target: false),
                dialogOpen: _dialogOpen,
                controlsInteraction: widget.controlsInteraction,
                onControlsVisibility: widget.onControlsVisibility,
              )
            : SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: model.showAudioPage
                          ? AudioPage(
                              model: model,
                              actionFocus: _homeFocus,
                              onSettings: _settings,
                            )
                          : HomePage(
                              model: model,
                              actionFocus: _homeFocus,
                              onToggle: _toggleReceiver,
                              onSettings: _settings,
                              onLogs: _logs,
                            ),
                    ),
                  ],
                ),
              ),
      ),
    ),
  );

  Future<void> _settings({bool editName = false}) async {
    if (_dialogOpen || !model.loaded) return;
    setState(() => _dialogOpen = true);
    widget.onDialogVisibility?.call(true);
    var openLogs = false;
    final page = SettingsPage(
      model: model,
      editName: editName,
      onLogs: () => openLogs = true,
      launchAtLogin: widget.launchAtLogin,
    );
    if (model.supportsWindowPreferences) {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(context)
            .modalBarrierDismissLabel,
        pageBuilder: (context, animation, secondary) => Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: 480, height: double.infinity, child: page),
        ),
        transitionBuilder: (context, animation, secondary, child) =>
            SlideTransition(
              position: Tween(
                begin: const Offset(0, -.1),
                end: Offset.zero,
              ).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
      );
    } else {
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => page));
    }
    if (!mounted) return;
    setState(() => _dialogOpen = false);
    widget.onDialogVisibility?.call(false);
    if (openLogs) {
      await _logs();
    } else {
      _restoreFocus();
    }
  }

  Future<void> _logs() async {
    if (_dialogOpen) return;
    setState(() => _dialogOpen = true);
    widget.onDialogVisibility?.call(true);
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => LogsPage(model: model)));
    if (mounted) {
      setState(() => _dialogOpen = false);
      widget.onDialogVisibility?.call(false);
      _restoreFocus();
    }
  }
}
