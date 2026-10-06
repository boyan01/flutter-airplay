// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Marks a custom focus target without adding another traversal stop.
class TvFocus extends StatelessWidget {
  const TvFocus({super.key, required this.child});
  final Widget child;

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

class _TvFocusScopeState extends State<TvFocusScope> {
  final _surface = GlobalKey();
  Rect? _target;
  bool _scheduled = false;
  final _routeAnimations = <Animation<double>>[];

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(TvFocusScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _focusChanged();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    for (final animation in _routeAnimations) {
      animation.removeListener(_schedule);
    }
    super.dispose();
  }

  void _focusChanged() {
    for (final animation in _routeAnimations) {
      animation.removeListener(_schedule);
    }
    _routeAnimations.clear();
    if (!widget.enabled) return;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && focused.mounted) {
      final route = ModalRoute.of(focused);
      for (final animation in [route?.animation, route?.secondaryAnimation]) {
        if (animation != null) {
          _routeAnimations.add(animation);
          animation.addListener(_schedule);
        }
      }
    }
    _schedule();
  }

  void _schedule() {
    if (!widget.enabled || _scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final next = _focusedBounds();
      if (next != _target) setState(() => _target = next);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Rect? _focusedBounds() {
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
          widget is ListTile ||
          widget is TextField ||
          widget is TvFocus) {
        target = element;
        return false;
      }
      return true;
    });
    final box = target?.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return null;
    }
    final route = ModalRoute.of(target!);
    if (route != null && !route.isCurrent) return null;
    final rect = box.localToGlobal(Offset.zero, ancestor: surface) & box.size;
    var viewport = Offset.zero & surface.size;
    for (
      RenderObject? ancestor = box.parent;
      ancestor != null && ancestor != surface;
      ancestor = ancestor.parent
    ) {
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
    return rect.inflate(3).intersect(viewport);
  }

  // A target can move without changing focus (scroll, resize or route animation).
  // Measure after paint only when its destination changes; never drive an idle loop.
  void _painted() {
    if (widget.enabled && _focusedBounds() != _target) _schedule();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: _surface,
      fit: StackFit.expand,
      children: [
        _FocusGeometry(
          onPaint: _painted,
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _schedule();
              return false;
            },
            child: widget.child,
          ),
        ),
        if (widget.enabled && _target != null) _ring(context, _target!),
      ],
    );
  }

  Widget _ring(BuildContext context, Rect target) => AnimatedPositioned(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180),
    curve: Curves.easeOutCubic,
    left: target.left,
    top: target.top,
    width: target.width,
    height: target.height,
    child: IgnorePointer(
      child: DecoratedBox(
        key: const Key('tvFocusRing'),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: 3),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
  );
}

class _FocusGeometry extends SingleChildRenderObjectWidget {
  const _FocusGeometry({required this.onPaint, required super.child});
  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _FocusGeometryBox(onPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    _FocusGeometryBox renderObject,
  ) {
    renderObject.onPaint = onPaint;
  }
}

class _FocusGeometryBox extends RenderProxyBox {
  _FocusGeometryBox(this.onPaint);
  VoidCallback onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }
}
