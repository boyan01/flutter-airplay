// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../receiver/receiver_model.dart';
import 'receiver_strings.dart';
import 'home_page.dart';
import 'audio_page.dart';
import 'player_page.dart';
import 'settings_page.dart';
import 'logs_page.dart';
import 'desktop_window_bar.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key, required this.model});
  final ReceiverModel model;

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  static const _window = MethodChannel('tech.soit.flutterairplay/window');
  final _homeFocus = FocusNode(debugLabel: 'Home action');
  bool _dialogOpen = false;
  bool _maximized = false;
  String _windowLocale = '';
  bool _playing = false;
  bool _connected = false;
  String _homeAction = '';
  String _presentationMode = '';
  ReceiverModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _window.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'openSettings') {
        await _settings();
      } else if (call.method == 'openLogs') {
        await _logs();
      } else if (call.method == 'toggleReceiver') {
        if (model.canStop) {
          await model.stop();
        } else if (model.canStart) {
          await model.start(model.name, model.path);
        }
      } else if (call.method == 'disconnectSession') {
        await model.disconnect();
      } else if (call.method == 'toggleOnTop') {
        await model.save(
          model.name,
          model.path,
          desktopOptions: {
            ...model.desktopOptions,
            'alwaysOnTop': !model.desktopOptions['alwaysOnTop']!,
          },
        );
      } else if (call.method == 'windowStateChanged') {
        final state = Map<Object?, Object?>.from(call.arguments as Map);
        setState(
          () => _maximized =
              state['maximized'] == true || state['fullscreen'] == true,
        );
      }
    });
    model.addListener(_changed);
    model.initialize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setWindowStrings();
  }

  Future<void> _setWindowStrings() async {
    if (!model.loaded || !{'windows', 'linux'}.contains(model.platform)) return;
    final locale = Localizations.localeOf(context).toLanguageTag();
    if (_windowLocale == locale) return;
    _windowLocale = locale;
    final strings = l10n(context);
    try {
      await _window.invokeMethod<void>('setStrings', {
        'openApp': strings.openApp,
        'showPlayer': strings.showPlayer,
        'receive': strings.receive,
        'disconnect': strings.disconnect,
        'settings': strings.settings,
        'logs': strings.logs,
        'quitApp': strings.quitApp,
        'discoverable': strings.discoverable,
        'off': strings.off,
        'starting': strings.starting,
        'unavailable': strings.unavailable,
        'playing': strings.playing,
        'audioPlaying': strings.audioPlaying,
        'actualSize': strings.actualSize,
        'fitScreen': strings.fitScreen,
        'alwaysOnTop': strings.alwaysOnTop,
        'enterFullscreen': strings.enterFullscreen,
        'exitFullscreen': strings.exitFullscreen,
      });
    } on MissingPluginException {
      // A widget-test host has no native presentation adapter.
    }
  }

  void _changed() {
    _setWindowStrings();
    final playing = model.hasVideo;
    final mode = playing
        ? 'player:${model.videoWidth}:${model.videoHeight}'
        : 'home';
    if (model.loaded && mode != _presentationMode) {
      _presentationMode = mode;
      _setWindowMode(playing);
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

  Future<void> _setWindowMode(bool playing) async {
    try {
      await _window.invokeMethod<void>('setMode', {
        'mode': playing ? 'player' : 'home',
        'width': model.videoWidth,
        'height': model.videoHeight,
      });
    } on MissingPluginException {
      // A widget-test host has no native presentation adapter.
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
      await _window.invokeMethod<void>(
        target == false ? 'exitFullscreen' : 'toggleFullscreen',
      );
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
    _window.setMethodCallHandler(null);
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
          const SingleActivator(LogicalKeyboardKey.f11): _toggleFullscreen,
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (!_dialogOpen) _toggleFullscreen(target: false);
          },
          const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
              _window.invokeMethod<void>('closeWindow'),
          const SingleActivator(LogicalKeyboardKey.keyQ, control: true): () =>
              _window.invokeMethod<void>('quitApp'),
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
                maximized: _maximized,
              )
            : SafeArea(
                child: Column(
                  children: [
                    if (model.supportsWindowPreferences)
                      DesktopWindowBar(
                        title: 'Flutter AirPlay',
                        platform: model.platform,
                        maximized: _maximized,
                      ),
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
    final page = SettingsPage(model: model, editName: editName, onLogs: _logs);
    if (model.supportsWindowPreferences) {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(context)
            .modalBarrierDismissLabel,
        pageBuilder: (context, animation, secondary) => Column(
          children: [
            Material(
              child: DesktopWindowBar(
                title: 'Flutter AirPlay',
                platform: model.platform,
                maximized: _maximized,
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: 480,
                  height: double.infinity,
                  child: page,
                ),
              ),
            ),
          ],
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
    _restoreFocus();
  }

  Future<void> _logs() async {
    if (_dialogOpen) return;
    setState(() => _dialogOpen = true);
    await Navigator.of(context)
        .push<void>(MaterialPageRoute(builder: (_) => LogsPage(model: model)));
    if (mounted) {
      setState(() => _dialogOpen = false);
      _restoreFocus();
    }
  }
}
