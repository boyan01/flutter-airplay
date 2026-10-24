// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// TV navigation feedback keeps animating when Android reports disabled
// transition animations: some launchers ship with that scale set to zero.
// Controllers opt out with AnimationBehavior.preserve; the default behavior
// shortens them to 5%.
const _motionDuration = Duration(milliseconds: 220);
const _curve = Curves.easeOutCubic;

// Room kept around a target scrolled into view for its growth and outline.
const _scrollMargin = 16.0;

/// Marks a custom focus target without adding another traversal stop.
///
/// On TV the target grows slightly while it contains focus.
class TvFocus extends StatefulWidget {
  const TvFocus({
    super.key,
    this.borderRadius,
    this.scales = true,
    required this.child,
  });
  final Widget child;

  /// Overrides the outline for custom controls without a Material shape.
  final BorderRadius? borderRadius;

  /// Disables growth for targets whose bounds carry meaning, such as a crop.
  final bool scales;

  @override
  State<TvFocus> createState() => _TvFocusState();
}

class _TvFocusState extends State<TvFocus> with SingleTickerProviderStateMixin {
  late final _scale = AnimationController(
    vsync: this,
    duration: _motionDuration,
    animationBehavior: AnimationBehavior.preserve,
  );
  late final _progress = CurvedAnimation(parent: _scale, curve: _curve);
  bool _focused = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(TvFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _progress.dispose();
    _scale.dispose();
    super.dispose();
  }

  void _focusChanged(bool focused) {
    _focused = focused;
    _sync();
  }

  void _sync() {
    final enabled =
        widget.scales &&
        (context
                .dependOnInheritedWidgetOfExactType<_TvFocusEnabled>()
                ?.enabled ??
            false);
    if (!enabled) {
      _scale.value = 0;
    } else if (_focused) {
      _scale.forward();
    } else {
      _scale.reverse();
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    includeSemantics: false,
    onFocusChange: _focusChanged,
    child: _FocusScale(progress: _progress, child: widget.child),
  );
}

class _TvFocusEnabled extends InheritedWidget {
  const _TvFocusEnabled({required this.enabled, required super.child});
  final bool enabled;

  @override
  bool updateShouldNotify(_TvFocusEnabled oldWidget) =>
      enabled != oldWidget.enabled;
}

/// Grows each edge by at most 8 logical pixels, so wide rows barely move.
class _FocusScale extends SingleChildRenderObjectWidget {
  const _FocusScale({required this.progress, super.child});
  final Animation<double> progress;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFocusScale(progress);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFocusScale renderObject,
  ) {
    renderObject.progress = progress;
  }
}

class _RenderFocusScale extends RenderTransform {
  _RenderFocusScale(this._progress)
    : super(transform: Matrix4.identity(), alignment: Alignment.center);

  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (value == _progress) return;
    if (attached) {
      _progress.removeListener(_update);
      value.addListener(_update);
    }
    _progress = value;
    _update();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(_update);
  }

  @override
  void detach() {
    _progress.removeListener(_update);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    _update();
  }

  void _update() {
    if (!hasSize) return;
    final side = size.longestSide;
    final growth = side > 0 ? math.min(16 / side, 0.06) : 0.0;
    final scale = 1 + growth * _progress.value;
    transform = Matrix4.diagonal3Values(scale, scale, 1);
  }
}

/// One passive focus ring for all TV routes, dialogs and playback controls.
class TvFocusScope extends StatefulWidget {
  const TvFocusScope({super.key, required this.enabled, required this.child});
  final bool enabled;
  final Widget child;

  @override
  State<TvFocusScope> createState() => _TvFocusScopeState();
}

typedef _FocusTarget = ({
  Element element,
  ModalRoute<dynamic>? route,
  Rect rect,
  Rect viewport,
  BorderRadius radius,
});

typedef _Outline = ({Rect rect, Rect viewport, BorderRadius radius});

class _TvFocusScopeState extends State<TvFocusScope>
    with SingleTickerProviderStateMixin {
  final _surface = GlobalKey();
  // Scroll the next D-pad target into view with room for its outline,
  // animating instead of jumping to it.
  final _tvTraversal = ReadingOrderTraversalPolicy(
    requestFocusCallback:
        (node, {alignment, alignmentPolicy, curve, duration}) {
          node.requestFocus();
          final box = node.context?.findRenderObject();
          if (box is! RenderBox || !box.hasSize) return;
          box.showOnScreen(
            rect: (Offset.zero & box.size).inflate(_scrollMargin),
            duration: duration ?? _motionDuration,
            curve: curve ?? _curve,
          );
        },
  );
  final _defaultTraversal = ReadingOrderTraversalPolicy();
  late final _motion = AnimationController(
    vsync: this,
    duration: _motionDuration,
    value: 1,
    animationBehavior: AnimationBehavior.preserve,
  );
  late final _progress = CurvedAnimation(parent: _motion, curve: _curve);
  _FocusTarget? _target;

  /// Where the ring was drawn when focus moved; it eases toward the live target.
  _Outline? _from;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_schedule);
    WidgetsBinding.instance.addPostFrameCallback(_trackGeometry);
  }

  @override
  void didUpdateWidget(TvFocusScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _schedule();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_schedule);
    _progress.dispose();
    _motion.dispose();
    super.dispose();
  }

  void _schedule() {
    if (widget.enabled && mounted) {
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  // Observe frames the app already draws, including changes inside repaint
  // boundaries. Registering the next callback does not schedule an idle frame.
  void _trackGeometry(Duration _) {
    if (!mounted) return;
    final next = _focusedBounds();
    final previous = _target;
    if (next != previous) {
      final sameRoute =
          next != null && previous != null && next.route == previous.route;
      final moved = sameRoute && next.element != previous.element;
      setState(() {
        // Scroll, resize and growth keep easing toward the moving control;
        // route transitions and hidden targets snap.
        if (moved) {
          _from = _outline(previous);
        } else if (!sameRoute) {
          _from = null;
        }
        _target = next;
      });
      if (moved) {
        _motion.forward(from: 0);
      } else if (!sameRoute) {
        _motion.value = 1;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback(_trackGeometry);
  }

  _Outline _outline(_FocusTarget target) {
    final from = _from;
    final t = _progress.value;
    if (from == null || t == 1) {
      return (
        rect: target.rect,
        viewport: target.viewport,
        radius: target.radius,
      );
    }
    return (
      rect: Rect.lerp(from.rect, target.rect, t)!,
      viewport: Rect.lerp(from.viewport, target.viewport, t)!,
      radius: BorderRadius.lerp(from.radius, target.radius, t)!,
    );
  }

  _FocusTarget? _focusedBounds() {
    if (!widget.enabled) return null;
    final focused = FocusManager.instance.primaryFocus?.context;
    final surface = _surface.currentContext?.findRenderObject();
    if (focused == null ||
        !focused.mounted ||
        surface is! RenderBox ||
        !surface.hasSize) {
      return null;
    }
    Element? target;
    focused.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is ButtonStyleButton ||
          widget is IconButton ||
          widget is PopupMenuItem ||
          widget is ListTile ||
          widget is TextField ||
          widget is TvFocus) {
        target = element;
        return false;
      }
      return true;
    });
    if (target == null) return null;
    final element = target!;
    var box = element.findRenderObject();
    // Measure the grown child rather than the layout slot.
    if (box is _RenderFocusScale) box = box.child;
    ShapeBorder? shape;
    // Read the resolved Material shape, including widget state and theme overrides.
    // Use its painted bounds rather than the larger minimum touch target.
    if (element.widget is ButtonStyleButton || element.widget is IconButton) {
      void visit(Element child) {
        if (shape != null) return;
        if (child.widget case Material material) {
          shape =
              material.shape ??
              (material.type == MaterialType.circle
                  ? const CircleBorder()
                  : null);
          if (shape != null) box = child.findRenderObject();
          return;
        }
        child.visitChildren(visit);
      }

      element.visitChildren(visit);
    } else if (element.widget case ListTile tile) {
      shape =
          tile.shape ??
          ListTileTheme.of(element).shape ??
          const RoundedRectangleBorder();
    } else if (element.widget case TextField field) {
      final theme = Theme.of(element).inputDecorationTheme;
      shape =
          field.decoration?.focusedBorder ??
          theme.focusedBorder ??
          field.decoration?.border ??
          theme.border;
    }
    final radius = switch (shape) {
      CircleBorder() || StadiumBorder() => null,
      RoundedRectangleBorder(:final borderRadius) => borderRadius.resolve(
        Directionality.of(element),
      ),
      OutlineInputBorder(:final borderRadius) => borderRadius,
      _ =>
        element.widget is PopupMenuItem
            ? BorderRadius.zero
            : (element.widget is TvFocus
                      ? (element.widget as TvFocus).borderRadius
                      : null) ??
                  BorderRadius.circular(12),
    };
    final measuredBox = box;
    if (measuredBox is! RenderBox ||
        !measuredBox.attached ||
        !measuredBox.hasSize ||
        measuredBox.size.isEmpty) {
      return null;
    }
    final route = ModalRoute.of(element);
    if (route != null && !route.isCurrent) return null;
    final resolvedShape = shape;
    final rect = MatrixUtils.transformRect(
      measuredBox.getTransformTo(surface),
      resolvedShape is CircleBorder
          ? resolvedShape
                .getOuterPath(Offset.zero & measuredBox.size)
                .getBounds()
          : Offset.zero & measuredBox.size,
    );
    var viewport = Offset.zero & surface.size;
    for (
      RenderObject? ancestor = measuredBox.parent;
      ancestor != null && ancestor != surface;
      ancestor = ancestor.parent
    ) {
      if (ancestor is RenderOffstage && ancestor.offstage) return null;
      if (ancestor is RenderOpacity && ancestor.opacity == 0) return null;
      if (ancestor is RenderAnimatedOpacity && ancestor.opacity.value == 0) {
        return null;
      }
    }
    // Clip only along each scroll axis: a vertical list hides what scrolled
    // above or below it, while growth may extend past its sides.
    for (
      var scrollable = Scrollable.maybeOf(element);
      scrollable != null;
      scrollable = Scrollable.maybeOf(scrollable.context)
    ) {
      final box = scrollable.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final bounds = MatrixUtils.transformRect(
        box.getTransformTo(surface),
        Offset.zero & box.size,
      );
      viewport = switch (axisDirectionToAxis(scrollable.axisDirection)) {
        Axis.vertical => Rect.fromLTRB(
          viewport.left,
          math.max(viewport.top, bounds.top),
          viewport.right,
          math.min(viewport.bottom, bounds.bottom),
        ),
        Axis.horizontal => Rect.fromLTRB(
          math.max(viewport.left, bounds.left),
          viewport.top,
          math.min(viewport.right, bounds.right),
          viewport.bottom,
        ),
      };
      if (viewport.isEmpty) return null;
    }
    if (!rect.overlaps(viewport)) return null;
    return (
      element: element,
      route: route,
      rect: rect.inflate(3),
      viewport: viewport,
      radius: radius == null
          ? BorderRadius.circular(rect.shortestSide / 2 + 3)
          : radius == BorderRadius.zero
          ? radius
          : radius + BorderRadius.circular(3),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _TvFocusEnabled(
      enabled: widget.enabled,
      child: FocusTraversalGroup(
        policy: widget.enabled ? _tvTraversal : _defaultTraversal,
        child: Stack(
          key: _surface,
          fit: StackFit.expand,
          children: [
            widget.child,
            if (widget.enabled && _target != null) _ring(),
          ],
        ),
      ),
    );
  }

  Widget _ring() {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _progress,
          builder: (context, _) {
            final target = _target;
            if (target == null) return const SizedBox.shrink();
            final outline = _outline(target);
            return ClipRect(
              clipper: _FocusViewport(outline.viewport),
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: outline.rect,
                    child: SizedBox.expand(
                      key: const Key('tvFocusRing'),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 3),
                          borderRadius: outline.radius,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FocusViewport extends CustomClipper<Rect> {
  const _FocusViewport(this.viewport);
  final Rect viewport;

  @override
  Rect getClip(Size size) => viewport;

  @override
  bool shouldReclip(_FocusViewport oldClipper) =>
      viewport != oldClipper.viewport;
}
