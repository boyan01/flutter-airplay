// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'dart:ui' as ui show Gradient;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mixin_logger/mixin_logger.dart';

import '../../receiver/receiver_model.dart';
import '../../app/app_theme.dart';
import '../../platform/window_controller.dart';
import '../widgets/receiver_strings.dart';
import '../widgets/control_interaction_region.dart';
import '../tv_focus.dart';
import '../receiver_back.dart';
import 'playback_stats_overlay.dart';
import 'video_crop_editor.dart';
import 'playback_menu.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.model,
    required this.onFullscreen,
    required this.onEscape,
    required this.dialogOpen,
    this.onControlsVisibility,
    this.onCropEditingChanged,
    this.controlsInteraction,
    this.onWindowAction,
    this.window = const WindowController(),
  });
  final WindowController window;
  final ReceiverModel model;
  final VoidCallback onFullscreen, onEscape;
  final ValueChanged<WindowAction>? onWindowAction;
  final bool dialogOpen;
  final ValueListenable<bool>? controlsInteraction;
  final ValueChanged<bool>? onControlsVisibility;
  final ValueChanged<bool>? onCropEditingChanged;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final _surfaceFocus = FocusNode(debugLabel: 'Player surface');
  final _continueFocus = FocusNode(debugLabel: 'Continue watching');
  Timer? _timer, _backTimer;
  bool _visible = false, _confirmBack = false, _interacting = false;
  bool _windowMenuOpen = false;
  bool _editingCrop = false;
  Rect? _previewCrop;
  final _cropEntryFocus = FocusNode(debugLabel: 'Crop video');
  final _videoBounds = GlobalKey();
  bool _presentationScheduled = false;
  Rect _initialCrop = ReceiverModel.fullVideoCrop;
  (Rect, int, int, Rect)? _presentationSignature;
  int _cropRevision = 0;
  double? _editingAspect;
  Future<void> _presentationQueue = Future.value();

  Rect get _displayCrop => _editingCrop
      ? (_previewCrop ?? ReceiverModel.fullVideoCrop)
      : widget.model.videoCrop;

  void _editCrop() {
    _surfaceFocus.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    _timer?.cancel();
    _backTimer?.cancel();
    widget.onCropEditingChanged?.call(true);
    setState(() {
      _previewCrop = null;
      _initialCrop = widget.model.videoCrop;
      _editingCrop = true;
      _visible = false;
      _editingAspect = widget.model.videoWidth / widget.model.videoHeight;
      _confirmBack = false;
    });
    widget.onControlsVisibility?.call(false);
    _schedulePresentation();
  }

  void _finishCrop(Rect? crop) {
    if (!_editingCrop) return;
    _surfaceFocus.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    setState(() {
      _editingCrop = false;
      _previewCrop = null;
    });
    if (crop != null) widget.model.setVideoCrop(crop);
    widget.onCropEditingChanged?.call(false);
    _schedulePresentation();
    _show();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _cropEntryFocus.requestFocus();
      }
    });
  }

  void _schedulePresentation() {
    if (_presentationScheduled) return;
    _presentationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _presentationScheduled = false;
      if (mounted) _syncPresentation();
    });
  }

  void _syncPresentation() {
    if (!widget.model.usesNativeVideo) return;
    final crop = _displayCrop;
    final width = widget.model.videoWidth;
    final height = widget.model.videoHeight;
    final box = _videoBounds.currentContext?.findRenderObject();
    final view = View.of(context);
    final viewSize = view.physicalSize / view.devicePixelRatio;
    if (box is! RenderBox || !box.hasSize || viewSize.isEmpty) return;
    final origin = box.localToGlobal(Offset.zero);
    final viewport = Rect.fromLTWH(
      origin.dx / viewSize.width,
      origin.dy / viewSize.height,
      box.size.width / viewSize.width,
      box.size.height / viewSize.height,
    );
    if (viewport.isEmpty) return;
    final signature = (crop, width, height, viewport);
    if (_presentationSignature == signature) return;
    _presentationSignature = signature;
    _presentationQueue = _presentationQueue.then((_) async {
      if (!mounted || _presentationSignature != signature) return;
      try {
        i(
          '[Video crop] Native request: left=${crop.left} top=${crop.top} '
          'width=${crop.width} height=${crop.height} source=${width}x$height '
          'editing=$_editingCrop',
        );
        await widget.window.setVideoPresentation(
          left: crop.left,
          top: crop.top,
          width: crop.width,
          height: crop.height,
          sourceWidth: width,
          sourceHeight: height,
          viewport: viewport,
        );
        i('[Video crop] Native request completed');
      } catch (error) {
        e('[Video crop] Native request failed: $error');
        if (!mounted || _presentationSignature != signature) return;
        if (_editingCrop) {
          _finishCrop(null);
        } else if (widget.model.videoCrop != ReceiverModel.fullVideoCrop) {
          widget.model.setVideoCrop(ReceiverModel.fullVideoCrop);
        }
        widget.model.reportVideoPresentationError(error);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n(context).cropFailed)));
      }
    });
  }

  bool get _held =>
      (widget.controlsInteraction?.value ?? false) ||
      _interacting ||
      _windowMenuOpen ||
      _editingCrop;
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
    if (widget.dialogOpen || _editingCrop) return;
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
    _cropRevision = widget.model.videoCropRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPresentation();
    });
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
    if (_editingCrop) {
      if (_previewCrop != null) {
        setState(() => _previewCrop = null);
        _schedulePresentation();
        return;
      }
      _finishCrop(null);
      return;
    }
    if (!mobile) {
      widget.onEscape();
      return;
    }
    if (tv) {
      _visible ? _hide(force: true) : _show();
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
    final sourceChanged =
        _editingCrop &&
        (_editingAspect! - widget.model.videoWidth / widget.model.videoHeight)
                .abs() >
            .005;
    if (sourceChanged) {
      _editingCrop = false;
      _previewCrop = null;
      widget.onCropEditingChanged?.call(false);
      _show();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _cropEntryFocus.requestFocus();
      });
    }
    if (sourceChanged || _cropRevision != widget.model.videoCropRevision) {
      _cropRevision = widget.model.videoCropRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n(context).cropResetOnResize)),
          );
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPresentation();
    });
    if (widget.controlsInteraction != oldWidget.controlsInteraction) {
      oldWidget.controlsInteraction?.removeListener(
        _externalInteractionChanged,
      );
      widget.controlsInteraction?.addListener(_externalInteractionChanged);
    }
    if (widget.dialogOpen && !oldWidget.dialogOpen) {
      if (_editingCrop) widget.onCropEditingChanged?.call(false);
      _editingCrop = false;
      _previewCrop = null;
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
    if (_editingCrop) widget.onCropEditingChanged?.call(false);
    _cropEntryFocus.dispose();
    _surfaceFocus.dispose();
    _continueFocus.dispose();
    super.dispose();
  }

  Widget _moreMenu(BuildContext context, {required bool showLabel}) {
    final strings = l10n(context);
    void closed() {
      _windowMenuOpen = false;
      _scheduleHide();
    }

    return TvFocus(
      child: PlaybackMenu<WindowAction>(
        key: const Key('playerWindowMenu'),
        tooltip: strings.playbackMore,
        width: 240 * MediaQuery.textScalerOf(context).scale(1),
        onOpened: () {
          _windowMenuOpen = true;
          _timer?.cancel();
        },
        onCanceled: closed,
        onSelected: (action) {
          closed();
          if (action == WindowAction.disconnectSession) {
            widget.model.disconnect();
          } else {
            widget.onWindowAction?.call(action);
          }
        },
        items: [
          if (widget.model.supportsWindowPreferences) ...[
            playbackMenuItem(
              context,
              value: WindowAction.actualSize,
              label: strings.actualSize,
              icon: Icons.aspect_ratio_rounded,
              enabled: widget.onWindowAction != null,
              television: tv,
            ),
            playbackMenuItem(
              context,
              value: WindowAction.fitScreen,
              label: strings.fitScreen,
              icon: Icons.fit_screen_rounded,
              enabled: widget.onWindowAction != null,
              television: tv,
            ),
            playbackMenuItem(
              context,
              value: WindowAction.toggleOnTop,
              label: strings.alwaysOnTop,
              icon: Icons.push_pin_outlined,
              selected: widget.model.desktopOptions['alwaysOnTop']!,
              enabled: widget.model.editable && widget.onWindowAction != null,
              television: tv,
            ),
            const PopupMenuDivider(height: 13),
          ],
          playbackMenuItem(
            context,
            key: const Key('disconnect'),
            value: WindowAction.disconnectSession,
            label: strings.disconnect,
            icon: Icons.eject_rounded,
            enabled: widget.model.canStop,
            destructive: true,
            television: tv,
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            height: tv ? 56 : 48,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.more_horiz_rounded,
                  size: 22,
                  semanticLabel: showLabel ? null : strings.playbackMore,
                ),
                if (showLabel) ...[
                  const SizedBox(width: 8),
                  Text(strings.playbackMore),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strings = l10n(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final compact =
            !tv && constraints.maxWidth < (mobile ? 280 : 420) * scale;
        Widget action(
          String key,
          String label,
          IconData icon,
          VoidCallback onPressed, {
          FocusNode? focusNode,
        }) {
          final style = TextButton.styleFrom(
            foregroundColor: colors.onSurface,
            minimumSize: Size(48, tv ? 56 : 48),
            visualDensity: VisualDensity.standard,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          );
          return TvFocus(
            child: compact
                ? SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      key: Key(key),
                      focusNode: focusNode,
                      tooltip: label,
                      onPressed: onPressed,
                      icon: Icon(icon, size: 22),
                      style: IconButton.styleFrom(
                        foregroundColor: colors.onSurface,
                      ),
                    ),
                  )
                : TextButton.icon(
                    key: Key(key),
                    focusNode: focusNode,
                    style: style,
                    onPressed: onPressed,
                    icon: Icon(icon, size: 22),
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
          child: Material(
            color: colors.surfaceContainerLow.withValues(alpha: .96),
            elevation: 4,
            shadowColor: Colors.black.withValues(alpha: .18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: colors.outlineVariant.withValues(alpha: .5),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (tv)
                    action(
                      'continueWatching',
                      strings.continueWatching,
                      Icons.play_arrow_rounded,
                      () => _hide(force: true),
                      focusNode: _continueFocus,
                    ),
                  action(
                    'cropVideo',
                    strings.cropVideo,
                    Icons.crop_rounded,
                    _editCrop,
                    focusNode: _cropEntryFocus,
                  ),
                  if (!mobile)
                    action(
                      'playerFullscreen',
                      strings.playbackFullscreen,
                      Icons.fullscreen,
                      widget.onFullscreen,
                    ),
                  _moreMenu(context, showLabel: !compact && (tv || mobile)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _controls() => Theme(
    data: playbackTheme(Theme.of(context)),
    child: Builder(builder: _themedControls),
  );

  Widget _themedControls(BuildContext context) {
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
                  Align(
                    alignment: tv
                        ? Alignment.centerLeft
                        : Alignment.bottomCenter,
                    child: _toolbar(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _video(Rect crop) => LayoutBuilder(
    builder: (context, constraints) {
      _schedulePresentation();
      return Center(
        child: Semantics(
          label: l10n(context).videoLabel,
          image: true,
          child: AspectRatio(
            key: _videoBounds,
            aspectRatio:
                widget.model.videoWidth *
                crop.width /
                (widget.model.videoHeight * crop.height),
            child: widget.model.usesNativeVideo
                ? CustomPaint(
                    painter: widget.model.platform == 'macos'
                        ? const _NativeVideoBackingPainter()
                        : null,
                    child: const SizedBox.expand(
                      key: Key('nativeVideoSurface'),
                    ),
                  )
                : ClipRect(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth / crop.width;
                        final height = constraints.maxHeight / crop.height;
                        return Stack(
                          children: [
                            Positioned(
                              left: -crop.left * width,
                              top: -crop.top * height,
                              width: width,
                              height: height,
                              child: Texture(textureId: widget.model.textureId),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: Focus(
      focusNode: _surfaceFocus,
      skipTraversal: true,
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyUpEvent || widget.dialogOpen || _editingCrop) {
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
      child: SizedBox(
        key: const Key('playerPage'),
        child: MouseRegion(
          cursor: !mobile && !_visible && !_editingCrop && !widget.dialogOpen
              ? SystemMouseCursors.none
              : MouseCursor.defer,
          onEnter: (event) {
            if (event.kind == PointerDeviceKind.mouse) _show();
          },
          onHover: (_) => _show(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_editingCrop)
                VideoCropEditor(
                  sourceWidth: widget.model.videoWidth,
                  sourceHeight: widget.model.videoHeight,
                  initialCrop: _initialCrop,
                  television: tv,
                  previewing: _previewCrop != null,
                  videoBuilder: (_, crop) => _video(crop),
                  onPreviewChanged: (crop) {
                    setState(() => _previewCrop = crop);
                    _schedulePresentation();
                  },
                  onApply: _finishCrop,
                  onCancel: () => _finishCrop(null),
                )
              else
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _visible ? _hide(force: true) : _show(),
                  onDoubleTap: mobile ? null : widget.onFullscreen,
                  child: _video(_displayCrop),
                ),
              IgnorePointer(
                ignoring: !_visible || _editingCrop,
                child: ExcludeFocus(
                  excluding: !_visible || _editingCrop,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _visible && !_editingCrop
                        ? _controls()
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// An empty Flutter scene makes the macOS embedder wait for resize completion
// until it times out (flutter/flutter#190075). A transparent shader retains a
// backing surface without tinting or covering the native video underneath.
class _NativeVideoBackingPainter extends CustomPainter {
  const _NativeVideoBackingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, 0),
          const [Colors.transparent, Colors.transparent],
        ),
    );
  }

  @override
  bool shouldRepaint(_NativeVideoBackingPainter oldDelegate) => false;
}
