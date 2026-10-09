// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app/app_logging.dart';
import '../receiver/receiver_model.dart';
import '../platform/window_controller.dart';
import '../platform/app_updates.dart';
import '../platform/launch_at_login.dart';
import '../platform/desktop_presentation.dart';
import 'widgets/receiver_strings.dart';
import 'home/home_page.dart';
import 'playback/audio_page.dart';
import 'playback/player_page.dart';
import 'settings/settings_page.dart';
import 'logs/logs_page.dart';
import 'updates/app_update_dialog.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({
    super.key,
    required this.model,
    this.launchAtLogin = const LaunchAtLogin(),
    this.window = const WindowController(),
    this.updates,
    this.updateRequests,
    this.onControlsVisibility,
    this.controlsInteraction,
    this.onDialogVisibility,
    this.onWindowExpanded,
  });
  final ReceiverModel model;
  final AppUpdates? updates;
  final Listenable? updateRequests;
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
  bool _dialogOpen = false, _updateDialogOpen = false;
  late final DesktopPresentation _desktop;
  bool _playing = false;
  String _orientationMode = '';
  bool _connected = false;
  String _homeAction = '';
  double _displayRefreshRate = 60;
  late final FlutterFrameDiagnostics _frameDiagnostics;
  late final AppLifecycleListener _lifecycle;
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
      updates: widget.updates,
    );
    widget.updates?.addListener(_updateDesktop);
    widget.updateRequests?.addListener(_openUpdate);
    _lifecycle = AppLifecycleListener(
      onResume: () => widget.updates?.checkIfDue(),
      onExitRequested: () async {
        // Native window-close notifications can outlive the Dart isolate.
        // Unregister FFI callbacks before allowing the host to terminate.
        _window.listen(null);
        widget.updates?.dispose();
        await _desktop.dispose();
        await _window.releaseNativeWindow();
        return AppExitResponse.exit;
      },
    );
    _window.listen(_windowAction);
    model.addListener(_changed);
    model.initialize();
  }

  Future<void> _windowAction(WindowAction action, bool expanded) async {
    try {
      if (!mounted) return;
      var receiverCommand = false;
      if (action == WindowAction.quitApp) {
        await _window.execute(WindowCommand.quitApp);
      } else if (action == WindowAction.updateCheckDue) {
        widget.updates?.checkIfDue();
      } else if (action == WindowAction.checkForUpdates) {
        final updates = widget.updates;
        if (updates == null) return;
        await _desktop.show();
        await _openUpdate();
      } else if (action == WindowAction.openApp) {
        await _desktop.show();
      } else if (action == WindowAction.closeRequested) {
        await _desktop.hide();
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
          receiverCommand = true;
          await model.stop();
        } else if (model.canStart) {
          receiverCommand = true;
          await model.start(model.name, model.path);
        }
      } else if (action == WindowAction.disconnectSession) {
        if (model.status == 'streaming' && model.canStop) {
          receiverCommand = true;
          await model.disconnect();
        }
      } else if (action == WindowAction.toggleOnTop && model.editable) {
        receiverCommand = true;
        await model.save(
          model.name,
          model.path,
          desktopOptions: {
            ...model.desktopOptions,
            'alwaysOnTop': !model.desktopOptions['alwaysOnTop']!,
          },
        );
      } else if (action == WindowAction.toggleFullscreen) {
        await _desktop.show();
        await _toggleFullscreen();
      } else if (action == WindowAction.enterFullscreen) {
        await _desktop.show();
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
      if (receiverCommand && model.commandError != null && mounted) {
        await _showActionError(
          PlatformException(
            code: 'receiver_error',
            message: model.commandError,
          ),
        );
      }
    } on MissingPluginException {
      // Widget tests do not have a desktop host.
    } on PlatformException catch (error) {
      await _showActionError(error);
    }
  }

  Future<void> _showActionError(PlatformException error) async {
    try {
      await _desktop.show();
    } on PlatformException {
      // Keep the original operation failure if revealing the window also fails.
    } on MissingPluginException {
      // Widget tests do not have a desktop host.
    }
    _windowError(error);
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
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(error.message ?? l10n(context).fullscreenFailed),
        ),
      );
  }

  void _changed() {
    if (model.loaded) unawaited(widget.updates?.initialize(model.platform));
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
    if (mounted && !_dialogOpen && !_updateDialogOpen && !model.hasVideo) {
      _homeFocus.requestFocus();
    }
  }

  void _toggleReceiver() {
    if (_dialogOpen || _updateDialogOpen) return;
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
      await _showActionError(error);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _frameDiagnostics.dispose();
    _window.listen(null);
    unawaited(_desktop.dispose().then((_) => _window.releaseNativeWindow()));
    widget.updates?.removeListener(_updateDesktop);
    widget.updateRequests?.removeListener(_openUpdate);
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
            if (!_dialogOpen &&
                !_updateDialogOpen &&
                model.status == 'streaming') {
              model.disconnect();
            }
          },
          const SingleActivator(LogicalKeyboardKey.digit0, control: true): () {
            if (!_dialogOpen && model.hasVideo) {
              _windowAction(WindowAction.actualSize, false);
            }
          },
          const SingleActivator(LogicalKeyboardKey.digit9, control: true): () {
            if (!_dialogOpen && model.hasVideo) {
              _windowAction(WindowAction.fitScreen, false);
            }
          },
        },
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            _toggleReceiver,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): _settings,
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true): _logs,
        const SingleActivator(LogicalKeyboardKey.period, meta: true): () {
          if (!_dialogOpen &&
              !_updateDialogOpen &&
              model.status == 'streaming') {
            model.disconnect();
          }
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
                onWindowAction: (action) => _windowAction(action, false),
                dialogOpen: _dialogOpen || _updateDialogOpen,
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

  Future<void> _openUpdate() async {
    final updates = widget.updates;
    if (!mounted || updates == null || _updateDialogOpen) return;
    setState(() => _updateDialogOpen = true);
    widget.onDialogVisibility?.call(true);
    if (!updates.hasUpdate && updates.canCheck) {
      unawaited(updates.check());
    }
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => ListenableBuilder(
          listenable: model,
          builder: (context, _) => AppUpdateDialog(
            updates: updates,
            currentVersion: model.buildVersion,
            connected: model.status == 'streaming',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _updateDialogOpen = false);
        widget.onDialogVisibility?.call(_dialogOpen);
        _restoreFocus();
      }
    }
  }

  Future<void> _settings({bool editName = false}) async {
    if (_dialogOpen || _updateDialogOpen || !model.loaded) return;
    setState(() => _dialogOpen = true);
    widget.onDialogVisibility?.call(true);
    var openLogs = false;
    final page = SettingsPage(
      model: model,
      editName: editName,
      onLogs: () => openLogs = true,
      launchAtLogin: widget.launchAtLogin,
      updates: widget.updates,
      onOpenUpdate: _openUpdate,
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
    if (_dialogOpen || _updateDialogOpen) return;
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
