// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../receiver/receiver_model.dart';
import 'receiver_strings.dart';
import 'home_page.dart';
import 'audio_page.dart';
import 'player_page.dart';
import 'settings_page.dart';
import 'mac_window_bar.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key, required this.model});
  final ReceiverModel model;

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  static const _window = MethodChannel('org.flutterairplay/window');
  final _homeFocus = FocusNode(debugLabel: 'Home action');
  bool _dialogOpen = false;
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
      }
    });
    model.addListener(_changed);
    model.initialize();
  }

  void _changed() {
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
    if (model.platform != 'macos') return;
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
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            _toggleReceiver,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): _settings,
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true): _logs,
        const SingleActivator(LogicalKeyboardKey.period, meta: true): () {
          if (!_dialogOpen && model.status == 'streaming') model.disconnect();
        },
      },
      child: Scaffold(
        backgroundColor: model.hasVideo ? Colors.black : null,
        body: model.hasVideo
            ? PlayerPage(
                model: model,
                onFullscreen: _toggleFullscreen,
                onEscape: () => _toggleFullscreen(target: false),
                dialogOpen: _dialogOpen,
              )
            : SafeArea(
                child: Column(
                  children: [
                    if (model.platform == 'macos')
                      const MacWindowBar(title: 'Flutter AirPlay'),
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
    if (model.platform == 'macos') {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(context)
            .modalBarrierDismissLabel,
        pageBuilder: (context, animation, secondary) => Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 480,
                maxHeight: MediaQuery.sizeOf(context).height - 24,
              ),
              child: page,
            ),
          ),
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
    await showDialog<void>(
      context: context,
      builder: (context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.goBack): () =>
              Navigator.pop(context),
        },
        child: ListenableBuilder(
          listenable: model,
          builder: (context, _) => AlertDialog(
            title: Text(l10n(context).logs),
            content: SizedBox(
              width: 680,
              height: math.min(360, MediaQuery.sizeOf(context).height * .45),
              child: model.logs.isEmpty
                  ? Text(l10n(context).noLogs)
                  : ListView.builder(
                      reverse: true,
                      itemCount: model.logs.length,
                      itemBuilder: (_, index) => SelectableText(
                        model.logs[model.logs.length - 1 - index].display,
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 12,
                          height: 1.6,
                        ),
                      ),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: model.logs.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: model.logText),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n(context).logsCopied)),
                          );
                        }
                      },
                child: Text(l10n(context).copyLogs),
              ),
              TextButton(
                onPressed: model.logs.isEmpty ? null : model.clearLogs,
                child: Text(l10n(context).clear),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n(context).back),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) {
      setState(() => _dialogOpen = false);
      _restoreFocus();
    }
  }
}
