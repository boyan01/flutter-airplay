// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Marks a custom focus target without adding another traversal stop.
class TvFocus extends StatelessWidget {
  const TvFocus({super.key, this.borderRadius, required this.child});
  final Widget child;

  /// Overrides the outline for custom controls without a Material shape.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) => child;
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

class _TvFocusScopeState extends State<TvFocusScope> {
  final _surface = GlobalKey();
  _FocusTarget? _target;
  bool _animate = false;

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
    if (next != _target) {
      setState(() {
        // Scroll, resize and route transitions stay attached to the control.
        _animate =
            next != null &&
            _target != null &&
            next.route == _target!.route &&
            next.element != _target!.element;
        _target = next;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback(_trackGeometry);
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
      if (ancestor is RenderBox &&
          ancestor is RenderAbstractViewport &&
          ancestor.hasSize) {
        viewport = viewport.intersect(
          ancestor.localToGlobal(Offset.zero, ancestor: surface) &
              ancestor.size,
        );
      }
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
    return Stack(
      key: _surface,
      fit: StackFit.expand,
      children: [
        widget.child,
        if (widget.enabled && _target != null) _ring(context, _target!),
      ],
    );
  }

  Widget _ring(BuildContext context, _FocusTarget target) {
    final duration = _animate && !MediaQuery.disableAnimationsOf(context)
        ? const Duration(milliseconds: 220)
        : Duration.zero;
    return Positioned.fill(
      child: IgnorePointer(
        child: ClipRect(
          clipper: _FocusViewport(target.viewport),
          child: Stack(
            key: ValueKey(target.route),
            children: [
              AnimatedPositioned(
                duration: duration,
                curve: Curves.easeOutCubic,
                left: target.rect.left,
                top: target.rect.top,
                width: target.rect.width,
                height: target.rect.height,
                child: AnimatedContainer(
                  key: const Key('tvFocusRing'),
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 3),
                    borderRadius: target.radius,
                  ),
                ),
              ),
            ],
          ),
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
