// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../receiver/receiver_model.dart';
import '../widgets/receiver_strings.dart';
import '../widgets/control_interaction_region.dart';
import '../tv_focus.dart';
import '../receiver_back.dart';
import 'playback_stats_overlay.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.model,
    required this.onFullscreen,
    required this.onEscape,
    required this.dialogOpen,
    this.onControlsVisibility,
    this.controlsInteraction,
  });
  final ReceiverModel model;
  final VoidCallback onFullscreen, onEscape;
  final bool dialogOpen;
  final ValueListenable<bool>? controlsInteraction;
  final ValueChanged<bool>? onControlsVisibility;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final _surfaceFocus = FocusNode(debugLabel: 'Player surface');
  final _continueFocus = FocusNode(debugLabel: 'Continue watching');
  Timer? _timer, _backTimer;
  bool _visible = false, _confirmBack = false, _interacting = false;
  bool get _held =>
      (widget.controlsInteraction?.value ?? false) || _interacting;
  bool get tv => widget.model.isTelevision;
  bool get mobile => widget.model.isMobile;
  Duration get _delay => Duration(
    milliseconds: tv
        ? 5000
        : mobile
        ? 3000
        : 2500,
  );
  String get client => widget.model.clientName?.isNotEmpty == true
      ? widget.model.clientName!
      : 'iPhone';

  void _show() {
    if (widget.dialogOpen) return;
    final newlyVisible = !_visible;
    if (newlyVisible) {
      setState(() => _visible = true);
      widget.onControlsVisibility?.call(true);
    }
    _scheduleHide();
    if (tv && newlyVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _visible) _continueFocus.requestFocus();
      });
    }
  }

  void _scheduleHide() {
    _timer?.cancel();
    if (_visible && !_held && !widget.dialogOpen) {
      _timer = Timer(_delay, _hide);
    }
  }

  void _externalInteractionChanged() {
    if (widget.controlsInteraction?.value ?? false) {
      _show();
    } else {
      _scheduleHide();
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controlsInteraction?.addListener(_externalInteractionChanged);
  }

  void _hide({bool force = false}) {
    if (_held && !force) return;
    _timer?.cancel();
    if (!mounted) return;
    setState(() {
      _visible = false;
      _interacting = false;
    });
    widget.onControlsVisibility?.call(false);
    // Passive auto-hide must not refocus an inactive native window. Flutter's
    // view focus bridge turns requestFocus into SetFocus on Windows.
    if (force || _surfaceFocus.hasFocus) _surfaceFocus.requestFocus();
  }

  void _back() {
    if (widget.dialogOpen) return;
    if (!mobile) {
      widget.onEscape();
      return;
    }
    if (tv) {
      _visible ? _hide() : _show();
      return;
    }
    if (_confirmBack) {
      widget.model.disconnect();
      return;
    }
    if (_visible) {
      _hide();
      return;
    }
    _show();
    setState(() => _confirmBack = true);
    _backTimer?.cancel();
    _backTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _confirmBack = false);
    });
  }

  @override
  void didUpdateWidget(PlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controlsInteraction != oldWidget.controlsInteraction) {
      oldWidget.controlsInteraction?.removeListener(
        _externalInteractionChanged,
      );
      widget.controlsInteraction?.addListener(_externalInteractionChanged);
    }
    if (widget.dialogOpen && !oldWidget.dialogOpen) {
      _interacting = false;
      _timer?.cancel();
      _backTimer?.cancel();
      _visible = false;
      _confirmBack = false;
    } else if (!widget.dialogOpen && oldWidget.dialogOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hide(force: true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _backTimer?.cancel();
    widget.controlsInteraction?.removeListener(_externalInteractionChanged);
    _surfaceFocus.dispose();
    _continueFocus.dispose();
    super.dispose();
  }

  Widget _disconnect() => FilledButton.icon(
    key: const Key('disconnect'),
    onPressed: widget.model.canStop ? widget.model.disconnect : null,
    icon: const Icon(Icons.eject_rounded),
    label: Text(l10n(context).disconnect),
  );

  Widget _controls() {
    final phone = mobile && !tv;
    return Stack(
      key: const Key('playerControls'),
      children: [
        if (widget.model.showPlaybackStats)
          Positioned(
            top: 60,
            left: 12,
            right: 12,
            bottom: 100,
            child: SafeArea(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: PlaybackStatsOverlay(model: widget.model),
                ),
              ),
            ),
          ),

        if (!tv && !widget.model.supportsWindowPreferences)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x99000000), Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    if (phone)
                      IconButton(
                        key: const Key('playerBack'),
                        tooltip: l10n(context).back,
                        color: Colors.white,
                        onPressed: _back,
                        icon: const Icon(Icons.arrow_back),
                      )
                    else
                      const SizedBox(width: 60),
                    Expanded(
                      child: Text(
                        client,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: tv
                    ? 48
                    : phone
                    ? 20
                    : 12,
                vertical: tv ? 48 : 20,
              ),
              decoration: tv || phone
                  ? const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xcc000000)],
                      ),
                    )
                  : null,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: tv
                    ? CrossAxisAlignment.start
                    : phone
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.center,
                children: [
                  if (tv || _confirmBack) ...[
                    Text(
                      _confirmBack
                          ? l10n(context).confirmBack
                          : l10n(context).clientPlaying(client),
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (tv)
                    Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        TvFocus(child: _disconnect()),
                        TvFocus(
                          child: OutlinedButton(
                            key: const Key('continueWatching'),
                            focusNode: _continueFocus,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _hide,
                            child: Text(l10n(context).continueWatching),
                          ),
                        ),
                      ],
                    )
                  else if (phone)
                    _disconnect()
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final scale =
                            MediaQuery.textScalerOf(context).scale(14) / 14;
                        final compact = constraints.maxWidth < 380 * scale;
                        Widget action(
                          String key,
                          String label,
                          IconData icon,
                          VoidCallback? onPressed,
                        ) {
                          if (compact) {
                            return IconButton(
                              key: Key(key),
                              tooltip: label,
                              color: Colors.white,
                              onPressed: onPressed,
                              icon: Icon(icon),
                              constraints: const BoxConstraints.tightFor(
                                width: 48,
                                height: 48,
                              ),
                            );
                          }
                          return SizedBox(
                            height: 48,
                            child: TextButton.icon(
                              key: Key(key),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                              ),
                              onPressed: onPressed,
                              icon: Icon(icon),
                              label: Text(label),
                            ),
                          );
                        }

                        return ControlInteractionRegion(
                          onChanged: (active) {
                            _interacting = active;
                            if (active) {
                              _show();
                            } else {
                              _scheduleHide();
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xdd202020),
                              borderRadius: BorderRadius.circular(32),
                            ),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              alignment: WrapAlignment.center,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                action(
                                  'disconnect',
                                  l10n(context).disconnect,
                                  Icons.eject_rounded,
                                  widget.model.canStop
                                      ? widget.model.disconnect
                                      : null,
                                ),
                                if (widget.model.supportsWindowPreferences)
                                  action(
                                    'playerAlwaysOnTop',
                                    l10n(context).alwaysOnTop,
                                    widget.model.desktopOptions['alwaysOnTop']!
                                        ? Icons.push_pin
                                        : Icons.push_pin_outlined,
                                    () => widget.model.save(
                                      widget.model.name,
                                      widget.model.path,
                                      desktopOptions: {
                                        ...widget.model.desktopOptions,
                                        'alwaysOnTop': !widget
                                            .model
                                            .desktopOptions['alwaysOnTop']!,
                                      },
                                    ),
                                  ),
                                SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: IconButton(
                                    tooltip: widget.model.platform != 'macos'
                                        ? l10n(context).fullscreenWindows
                                        : l10n(context).fullscreen,
                                    color: Colors.white,
                                    onPressed: widget.onFullscreen,
                                    icon: const Icon(Icons.fullscreen),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: Focus(
      focusNode: _surfaceFocus,
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyUpEvent || widget.dialogOpen) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (isReceiverBackKey(widget.model.platform, key)) {
          if (event is KeyDownEvent) _back();
          return KeyEventResult.handled;
        }
        if ({
          LogicalKeyboardKey.select,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.contextMenu,
        }.contains(key)) {
          if (!_visible) {
            _show();
            return KeyEventResult.handled;
          }
          _timer?.cancel();
          if (!_held) _timer = Timer(_delay, _hide);
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: !mobile && !_visible
            ? SystemMouseCursors.none
            : MouseCursor.defer,
        onEnter: (event) {
          if (event.kind == PointerDeviceKind.mouse) _show();
        },
        onHover: (_) => _show(),
        child: Stack(
          key: const Key('playerPage'),
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _visible ? _hide(force: true) : _show(),
              onDoubleTap: mobile ? null : widget.onFullscreen,
              child: Center(
                child: Semantics(
                  label: l10n(context).videoLabel,
                  image: true,
                  child: AspectRatio(
                    aspectRatio:
                        widget.model.videoWidth / widget.model.videoHeight,
                    child: widget.model.usesNativeVideo
                        ? const SizedBox.expand(key: Key('nativeVideoSurface'))
                        : Texture(textureId: widget.model.textureId),
                  ),
                ),
              ),
            ),
            IgnorePointer(
              ignoring: !_visible,
              child: ExcludeFocus(
                excluding: !_visible,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _visible ? _controls() : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
