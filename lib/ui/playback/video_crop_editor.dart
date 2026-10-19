// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../receiver_back.dart';
import '../tv_focus.dart';
import 'playback_menu.dart';
import '../widgets/receiver_strings.dart';

/// A crop editor with separate controls and a shared video/selection area.
/// Crop coordinates are normalized to the source. The owner closes this editor
/// when the source dimensions change and commits changes only through onApply.
/// The owner handles system Back through its PopScope; this overlay handles
/// Escape and goBack key events only.
class VideoCropEditor extends StatefulWidget {
  const VideoCropEditor({
    super.key,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.initialCrop,
    required this.onApply,
    required this.onCancel,
    required this.onPreviewChanged,
    required this.videoBuilder,
    this.previewing = false,
    this.television = false,
    this.platform = '',
  }) : assert(sourceWidth > 0),
       assert(sourceHeight > 0);

  final int sourceWidth;
  final int sourceHeight;
  final Rect initialCrop;
  final ValueChanged<Rect> onApply;
  final VoidCallback onCancel;
  final ValueChanged<Rect?> onPreviewChanged;
  final Widget Function(BuildContext, Rect) videoBuilder;
  final bool previewing;
  final bool television;
  // Android delivers Back through system navigation; see receiver_back.dart.
  final String platform;

  @override
  State<VideoCropEditor> createState() => _VideoCropEditorState();
}

class _VideoCropEditorState extends State<VideoCropEditor> {
  static const _full = Rect.fromLTWH(0, 0, 1, 1);
  // Each free-form dimension spans at least 5% of the source. A locked crop
  // satisfies both minima where the source aspect ratio permits it.
  static const _minimum = .05;
  final _cropFocus = FocusNode();
  final _moveFocus = FocusNode();
  final _resizeFocus = FocusNode();
  final _previewFocus = FocusNode();
  late Rect _crop;
  late bool _locked;
  bool _resizing = false;
  bool _dragging = false;

  double get _ratio => (16 / 9) * widget.sourceHeight / widget.sourceWidth;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialCrop;
    final valid =
        initial.left.isFinite &&
        initial.top.isFinite &&
        initial.right.isFinite &&
        initial.bottom.isFinite &&
        initial.width > 0 &&
        initial.height > 0;
    _crop = valid ? initial.intersect(_full) : _full;
    if (_crop.isEmpty) _crop = _full;
    if (_crop == _full) {
      _crop = _centered16By9();
      _locked = true;
    } else {
      _locked = (_crop.width / _crop.height - _ratio).abs() < .0001;
    }
  }

  @override
  void dispose() {
    _cropFocus.dispose();
    _moveFocus.dispose();
    _resizeFocus.dispose();
    _previewFocus.dispose();
    super.dispose();
  }

  Rect _centered16By9() {
    final width = math.min(1.0, _ratio);
    final height = width / _ratio;
    return Rect.fromCenter(
      center: const Offset(.5, .5),
      width: width,
      height: height,
    );
  }

  void _setRatio(bool locked) {
    setState(() {
      _locked = locked;
      if (!locked) return;
      final width = math.min(_crop.width, _crop.height * _ratio);
      final minimumWidth = math.min(
        math.min(1.0, _ratio),
        math.max(_minimum, _minimum * _ratio),
      );
      final newWidth = math.max(width, minimumWidth);
      _crop = _boundedCenter(_crop.center, newWidth, newWidth / _ratio);
    });
  }

  Rect _boundedCenter(Offset center, double width, double height) {
    return Rect.fromCenter(
      center: Offset(
        center.dx.clamp(width / 2, 1 - width / 2),
        center.dy.clamp(height / 2, 1 - height / 2),
      ),
      width: width,
      height: height,
    );
  }

  void _move(Offset delta) {
    setState(
      () => _crop = _boundedCenter(
        _crop.center + delta,
        _crop.width,
        _crop.height,
      ),
    );
  }

  void _resizeCorner(int corner, Offset delta) {
    final left = corner == 0 || corner == 2;
    final top = corner < 2;
    final anchor = Offset(
      left ? _crop.right : _crop.left,
      top ? _crop.bottom : _crop.top,
    );
    final maxWidth = left ? anchor.dx : 1 - anchor.dx;
    final maxHeight = top ? anchor.dy : 1 - anchor.dy;
    var width = _crop.width + (left ? -delta.dx : delta.dx);
    var height = _crop.height + (top ? -delta.dy : delta.dy);
    if (_locked) {
      // Follow the dominant source-space axis and keep the opposite corner fixed.
      if (delta.dx.abs() > (delta.dy * _ratio).abs()) {
        height = width / _ratio;
      } else {
        width = height * _ratio;
      }
      final maximum = math.min(maxWidth, maxHeight * _ratio);
      final minimum = math.min(maximum, math.max(_minimum, _minimum * _ratio));
      width = width.clamp(minimum, maximum);
      height = width / _ratio;
    } else {
      width = width.clamp(math.min(_minimum, maxWidth), maxWidth);
      height = height.clamp(math.min(_minimum, maxHeight), maxHeight);
    }
    setState(
      () => _crop = Rect.fromLTWH(
        left ? anchor.dx - width : anchor.dx,
        top ? anchor.dy - height : anchor.dy,
        width,
        height,
      ),
    );
  }

  void _resizeCenter(Offset delta) {
    final center = _crop.center;
    final maxWidth = 2.0 * math.min(center.dx, 1.0 - center.dx);
    final maxHeight = 2.0 * math.min(center.dy, 1.0 - center.dy);
    var width = _crop.width + delta.dx;
    var height = _crop.height + delta.dy;
    if (_locked) {
      width = _crop.width + (delta.dx != 0 ? delta.dx : delta.dy * _ratio);
      final maximum = math.min(maxWidth, maxHeight * _ratio);
      width = width.clamp(
        math.min(maximum, math.max(_minimum, _minimum * _ratio)),
        maximum,
      );
      height = width / _ratio;
    } else {
      width = width.clamp(math.min(_minimum, maxWidth), maxWidth);
      height = height.clamp(math.min(_minimum, maxHeight), maxHeight);
    }
    setState(
      () =>
          _crop = Rect.fromCenter(center: center, width: width, height: height),
    );
  }

  KeyEventResult _selectionKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.space) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      (widget.television
              ? (_resizing ? _resizeFocus : _moveFocus)
              : _previewFocus)
          .requestFocus();
      return KeyEventResult.handled;
    }
    // TV remotes have no modifier keys. Tap for source-pixel precision and
    // use the platform's key-repeat delay before taking larger held steps.
    final pixels = event is KeyRepeatEvent ? 8.0 : 1.0;
    final step = HardwareKeyboard.instance.isShiftPressed ? .05 : .01;
    final horizontal = widget.television ? pixels / widget.sourceWidth : step;
    final vertical = widget.television ? pixels / widget.sourceHeight : step;
    final delta = switch (key) {
      LogicalKeyboardKey.arrowLeft => Offset(-horizontal, 0),
      LogicalKeyboardKey.arrowRight => Offset(horizontal, 0),
      LogicalKeyboardKey.arrowUp => Offset(0, -vertical),
      LogicalKeyboardKey.arrowDown => Offset(0, vertical),
      _ => null,
    };
    if (delta == null) return KeyEventResult.ignored;
    if (_resizing) {
      _resizeCenter(delta);
    } else {
      _move(delta);
    }
    return KeyEventResult.handled;
  }

  void _edit(bool resize) {
    setState(() => _resizing = resize);
    _cropFocus.requestFocus();
  }

  @override
  void didUpdateWidget(VideoCropEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.previewing != widget.previewing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _previewFocus.requestFocus();
      });
    }
  }

  void _reset() {
    setState(() {
      _crop = _full;
      _locked =
          (widget.sourceWidth / widget.sourceHeight - 16 / 9).abs() < .0001;
    });
  }

  void _dragStarted() {
    _cropFocus.requestFocus();
    setState(() => _dragging = true);
  }

  void _dragEnded() => setState(() => _dragging = false);

  @override
  Widget build(BuildContext context) {
    final strings = l10n(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return FocusScope(
      onKeyEvent: (_, event) {
        // A held confirm must not reactivate the tool we just returned to.
        if (widget.television &&
            event is KeyRepeatEvent &&
            {
              LogicalKeyboardKey.enter,
              LogicalKeyboardKey.select,
              LogicalKeyboardKey.space,
            }.contains(event.logicalKey)) {
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            isReceiverBackKey(widget.platform, event.logicalKey)) {
          if (widget.previewing) {
            widget.onPreviewChanged(null);
          } else {
            widget.onCancel();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            Material(
              color: colors.surface,
              shape: Border(
                bottom: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: .5),
                ),
              ),
              child: SafeArea(
                bottom: false,
                minimum: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    if (constraints.maxWidth >=
                        280 * MediaQuery.textScalerOf(context).scale(1)) ...[
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer.withValues(alpha: .6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          widget.previewing
                              ? Icons.visibility_outlined
                              : Icons.crop_rounded,
                          size: 20,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Text(
                        widget.previewing
                            ? strings.cropPreviewTitle
                            : strings.cropVideo,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TvFocus(
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: colors.onSurfaceVariant,
                        ),
                        onPressed: widget.onCancel,
                        child: Text(strings.cancel),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: LayoutBuilder(
                  builder: (context, bounds) => _selection(context, bounds),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * .45,
              ),
              child: Material(
                color: colors.surfaceContainerLow,
                shape: Border(
                  top: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .5),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: SingleChildScrollView(child: _tools(context)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tools(BuildContext context) {
    final strings = l10n(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    );
    final height = widget.television ? 56.0 : 44.0;
    final secondaryStyle = OutlinedButton.styleFrom(
      minimumSize: Size(64, height),
      visualDensity: VisualDensity.standard,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shape: shape,
      foregroundColor: colors.onSurface,
      side: BorderSide(color: colors.outlineVariant),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final wide =
            constraints.maxWidth >=
            (widget.television ? 1040 : 720) * textScale;
        final settings = Visibility(
          visible: !widget.previewing,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: math.min(constraints.maxWidth, 190 * textScale),
                child: TvFocus(
                  child: PlaybackMenu<bool>(
                    key: const Key('cropRatio'),
                    tooltip: strings.cropRatio,
                    width: math.max(
                      220,
                      math.min(constraints.maxWidth, 190 * textScale),
                    ),
                    onSelected: _setRatio,
                    items: [
                      playbackMenuItem(
                        context,
                        value: true,
                        label: strings.cropRatio16By9,
                        icon: Icons.crop_16_9_rounded,
                        selected: _locked,
                        television: widget.television,
                      ),
                      playbackMenuItem(
                        context,
                        value: false,
                        label: strings.cropRatioFree,
                        icon: Icons.crop_free_rounded,
                        selected: !_locked,
                        television: widget.television,
                      ),
                    ],
                    child: Container(
                      constraints: BoxConstraints(minHeight: height),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: colors.outlineVariant.withValues(alpha: .5),
                        ),
                      ),
                      child: Row(
                        children: [
                          Text(
                            strings.cropRatio,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _locked
                                  ? strings.cropRatio16By9
                                  : strings.cropRatioFree,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.expand_more_rounded, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              TvFocus(
                child: Tooltip(
                  message: strings.cropRestoreFull,
                  child: TextButton.icon(
                    key: const Key('cropReset'),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.onSurfaceVariant,
                      shape: shape,
                      minimumSize: Size(64, height),
                      visualDensity: VisualDensity.standard,
                    ),
                    onPressed: _reset,
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: Text(strings.cropReset),
                  ),
                ),
              ),
              if (widget.television) ...[
                TvFocus(
                  child: OutlinedButton(
                    style: secondaryStyle,
                    focusNode: _moveFocus,
                    autofocus: true,
                    onPressed: () => _edit(false),
                    child: Text(strings.cropMove),
                  ),
                ),
                TvFocus(
                  child: OutlinedButton(
                    style: secondaryStyle,
                    focusNode: _resizeFocus,
                    onPressed: () => _edit(true),
                    child: Text(strings.cropResize),
                  ),
                ),
              ],
            ],
          ),
        );
        final actions = Wrap(
          alignment: WrapAlignment.end,
          spacing: 12,
          runSpacing: 8,
          children: [
            TvFocus(
              child: OutlinedButton.icon(
                key: const Key('cropPreview'),
                focusNode: _previewFocus,
                style: secondaryStyle,
                onPressed: () =>
                    widget.onPreviewChanged(widget.previewing ? null : _crop),
                icon: Icon(
                  widget.previewing
                      ? Icons.tune_rounded
                      : Icons.visibility_outlined,
                  size: 18,
                ),
                label: IndexedStack(
                  index: widget.previewing ? 1 : 0,
                  alignment: Alignment.center,
                  children: [
                    Text(strings.cropPreview),
                    Text(strings.cropReturnToEdit),
                  ],
                ),
              ),
            ),
            TvFocus(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: Size(64, height),
                  visualDensity: VisualDensity.standard,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: shape,
                ),
                onPressed: () => widget.onApply(_crop),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(strings.cropApply),
              ),
            ),
          ],
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              Row(
                children: [
                  Expanded(child: settings),
                  const SizedBox(width: 20),
                  actions,
                ],
              )
            else ...[
              settings,
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight, child: actions),
            ],
            const SizedBox(height: 10),
            Text(
              widget.previewing
                  ? ''
                  : widget.television
                  ? (_cropFocus.hasFocus
                        ? (_resizing
                              ? strings.cropResizeActive
                              : strings.cropMoveActive)
                        : strings.cropTvHelp)
                  : strings.cropKeyboardHelp,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _selection(BuildContext context, BoxConstraints constraints) {
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(widget.sourceWidth.toDouble(), widget.sourceHeight.toDouble()),
      Size(
        math.max(0, constraints.maxWidth - 44),
        math.max(0, constraints.maxHeight - 44),
      ),
    ).destination;
    final video = Alignment.center.inscribe(
      fitted,
      Offset.zero & constraints.biggest,
    );
    final selection = Rect.fromLTWH(
      video.left + _crop.left * video.width,
      video.top + _crop.top * video.height,
      _crop.width * video.width,
      _crop.height * video.height,
    );
    Offset normalized(Offset delta) =>
        Offset(delta.dx / video.width, delta.dy / video.height);
    return Stack(
      key: const Key('cropEditingArea'),
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.all(22),
          child: widget.videoBuilder(
            context,
            widget.previewing ? _crop : _full,
          ),
        ),
        if (!widget.previewing) ...[
          IgnorePointer(
            child: CustomPaint(
              painter: _CropPainter(
                selection,
                _dragging || _cropFocus.hasFocus,
              ),
            ),
          ),
          Positioned.fromRect(
            rect: selection,
            child: TvFocus(
              borderRadius: BorderRadius.zero,
              child: Focus(
                focusNode: _cropFocus,
                autofocus: !widget.television,
                onKeyEvent: _selectionKey,
                onFocusChange: (_) => setState(() {}),
                child: Semantics(
                  label: l10n(context).cropSelection,
                  hint: l10n(context).cropKeyboardHelp,
                  child: MouseRegion(
                    cursor: _dragging
                        ? SystemMouseCursors.grabbing
                        : SystemMouseCursors.grab,
                    child: GestureDetector(
                      key: const Key('cropSelection'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _cropFocus.requestFocus(),
                      onPanStart: (_) => _dragStarted(),
                      onPanEnd: (_) => _dragEnded(),
                      onPanCancel: _dragEnded,
                      onPanUpdate: (details) =>
                          _move(normalized(details.delta)),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (var handle = 0; handle < 8; handle++)
            _handle(handle, selection, normalized),
        ],
      ],
    );
  }

  Widget _handle(
    int handle,
    Rect selection,
    Offset Function(Offset) normalized,
  ) {
    final point = switch (handle) {
      0 => selection.topLeft,
      1 => selection.topRight,
      2 => selection.bottomLeft,
      3 => selection.bottomRight,
      4 => selection.centerLeft,
      5 => selection.topCenter,
      6 => selection.centerRight,
      _ => selection.bottomCenter,
    };
    final cursor = switch (handle) {
      0 || 3 => SystemMouseCursors.resizeUpLeftDownRight,
      1 || 2 => SystemMouseCursors.resizeUpRightDownLeft,
      4 || 6 => SystemMouseCursors.resizeLeftRight,
      _ => SystemMouseCursors.resizeUpDown,
    };
    return Positioned(
      left: point.dx - 22,
      top: point.dy - 22,
      width: 44,
      height: 44,
      child: ExcludeSemantics(
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            key: Key(handle < 4 ? 'cropCorner$handle' : 'cropEdge$handle'),
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _dragStarted(),
            onPanEnd: (_) => _dragEnded(),
            onPanCancel: _dragEnded,
            onPanUpdate: (details) {
              final delta = normalized(details.delta);
              if (handle < 4) {
                _resizeCorner(handle, delta);
              } else {
                _resizeEdge(handle, delta);
              }
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  void _resizeEdge(int edge, Offset delta) {
    final horizontal = edge == 4 || edge == 6;
    final leading = edge == 4 || edge == 5;
    var width = _crop.width;
    var height = _crop.height;
    var center = _crop.center;
    if (horizontal) {
      final anchor = leading ? _crop.right : _crop.left;
      final maximum = math.min(
        leading ? anchor : 1 - anchor,
        _locked ? 2 * math.min(center.dy, 1 - center.dy) * _ratio : 1.0,
      );
      width = (width + (leading ? -delta.dx : delta.dx)).clamp(
        math.min(
          maximum,
          _locked ? math.max(_minimum, _minimum * _ratio) : _minimum,
        ),
        maximum,
      );
      if (_locked) height = width / _ratio;
      center = Offset(anchor + (leading ? -width / 2 : width / 2), center.dy);
    } else {
      final anchor = leading ? _crop.bottom : _crop.top;
      final maximum = math.min(
        leading ? anchor : 1 - anchor,
        _locked ? 2 * math.min(center.dx, 1 - center.dx) / _ratio : 1.0,
      );
      height = (height + (leading ? -delta.dy : delta.dy)).clamp(
        math.min(
          maximum,
          _locked ? math.max(_minimum, _minimum / _ratio) : _minimum,
        ),
        maximum,
      );
      if (_locked) width = height * _ratio;
      center = Offset(center.dx, anchor + (leading ? -height / 2 : height / 2));
    }
    setState(
      () =>
          _crop = Rect.fromCenter(center: center, width: width, height: height),
    );
  }
}

class _CropPainter extends CustomPainter {
  const _CropPainter(this.selection, this.showGrid);
  final Rect selection;
  final bool showGrid;

  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(selection);
    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withValues(alpha: .45),
    );
    canvas.drawRect(
      selection,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: .8),
    );
    final length = math.min(16.0, selection.shortestSide / 4);
    final corners = Path();
    for (final (point, dx, dy) in [
      (selection.topLeft, 1.0, 1.0),
      (selection.topRight, -1.0, 1.0),
      (selection.bottomLeft, 1.0, -1.0),
      (selection.bottomRight, -1.0, -1.0),
    ]) {
      corners.moveTo(point.dx, point.dy + dy * length);
      corners.lineTo(point.dx, point.dy);
      corners.lineTo(point.dx + dx * length, point.dy);
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      corners,
      stroke
        ..strokeWidth = 5
        ..color = Colors.black.withValues(alpha: .35),
    );
    canvas.drawPath(
      corners,
      stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
    for (final (point, width, height) in [
      (selection.centerLeft, 3.0, length),
      (selection.centerRight, 3.0, length),
      (selection.topCenter, length, 3.0),
      (selection.bottomCenter, length, 3.0),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: point, width: width, height: height),
          const Radius.circular(2),
        ),
        Paint()..color = Colors.white,
      );
    }
    if (!showGrid) return;
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: .45)
      ..strokeWidth = 1;
    for (var index = 1; index < 3; index++) {
      final x = selection.left + selection.width * index / 3;
      final y = selection.top + selection.height * index / 3;
      canvas.drawLine(
        Offset(x, selection.top),
        Offset(x, selection.bottom),
        grid,
      );
      canvas.drawLine(
        Offset(selection.left, y),
        Offset(selection.right, y),
        grid,
      );
    }
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      selection != oldDelegate.selection || showGrid != oldDelegate.showGrid;
}
